#!/usr/bin/env python3
"""Render the LidoLend API reference from the solc AST only — no forge doc, no userdoc/devdoc.

Everything comes from the compiler's AST (build it with `forge build --ast`):
  * contracts, functions, state variables, structs, enums  -> their `documentation` node
  * `@inheritdoc X` on a member is resolved here, by reading X's member documentation directly
    (userdoc/devdoc are lossy: they drop getters' @dev entirely and mush multi-@dev together)
  * signatures and types are rebuilt from the declaration nodes
  * `type Id` (solc never records its natspec anywhere) gets a hardcoded fallback line

Writes one Markdown page per contract under docs/specs/api/ (named after the contract). Run via `make doc`.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"

BASE = 2  # contract sections sit at `##`, members at `###`, under the page's `# Title`

IMORPHO = "IMorpho.sol/IMorpho.json"
CONTROLLER = "ILidoLendMarketController.sol/ILidoLendMarketController.json"
# Concrete controller impl: its on/marketId carry richer natspec than the fork base interface declares.
CONTROLLER_IMPL = "LidoLendMarketController.sol/LidoLendMarketController.json"
CONFIGURATOR = "ILidoLendMarketConfigurator.sol/ILidoLendMarketConfigurator.json"
# Fork core base controller interface, source of the hook types (HookEvent + *HookData). Same file name as the
# project's interface, so forge disambiguates its artifact under interfaces/.
BASE_CONTROLLER = "interfaces/ILidoLendMarketController.sol/ILidoLendMarketController.json"

# solc does not emit natspec for `type X is Y` into any artifact, so supply Id's line by hand.
ID_FALLBACK = "A market identifier, the `keccak256` hash of a `MarketParams`."


# --------------------------------------------------------------------------- ast access

def ast_of(rel: str) -> dict:
    path = OUT / rel
    if not path.exists():
        sys.exit(f"missing artifact: {path}\nrun `forge build --ast` first")
    art = json.loads(path.read_text())
    if "ast" not in art:
        sys.exit(f"{rel} has no `ast` — rebuild with `forge build --ast`")
    return art["ast"]


def doc_text(node: dict):
    d = node.get("documentation")
    return d.get("text") if isinstance(d, dict) else d if isinstance(d, str) else None


def find(node, node_type: str, name: str):
    if isinstance(node, dict):
        if node.get("nodeType") == node_type and node.get("name") == name:
            return node
        for v in node.values():
            hit = find(v, node_type, name)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find(v, node_type, name)
            if hit is not None:
                return hit
    return None


def find_all(node, node_type: str, acc=None):
    acc = [] if acc is None else acc
    if isinstance(node, dict):
        if node.get("nodeType") == node_type:
            acc.append(node)
        for v in node.values():
            find_all(v, node_type, acc)
    elif isinstance(node, list):
        for v in node:
            find_all(v, node_type, acc)
    return acc


# --------------------------------------------------------------------------- natspec

def parse_natspec(text):
    res = {"notice": None, "dev": [], "params": {}, "returns": [], "inheritdoc": None,
           "title": None, "author": None}
    if not text:
        return res
    tokens = re.split(r"@(\w+)", text)  # [preamble, tag, body, tag, body, ...]
    it = iter(tokens[1:])
    for tag, body in zip(it, it):
        flat = " ".join(body.split())  # single-line form for key/value tags
        if tag == "notice":
            res["notice"] = body.strip("\n")  # keep raw: @dev/@notice may carry lists and breaks
        elif tag == "dev":
            res["dev"].append(body.strip("\n"))
        elif tag == "param":
            name, _, desc = flat.partition(" ")
            res["params"][name] = desc
        elif tag == "return":
            res["returns"].append(flat)
        elif tag == "inheritdoc":
            res["inheritdoc"] = flat
        elif tag in ("title", "author"):
            res[tag] = flat
    return res


def build_registry(asts):
    """(interfaceName, memberName) -> raw natspec, for resolving `@inheritdoc` ourselves."""
    reg = {}
    for ast in asts:
        for c in find_all(ast, "ContractDefinition"):
            for m in c.get("nodes", []):
                if m.get("nodeType") == "FunctionDefinition" and m.get("name"):
                    reg[(c["name"], m["name"])] = doc_text(m)
    return reg


def resolve_doc(node, reg):
    """Parsed natspec for a member, following one level of `@inheritdoc` into the base interface."""
    nd = parse_natspec(doc_text(node))
    if nd["inheritdoc"]:
        base = reg.get((nd["inheritdoc"], node.get("name")))
        if base is not None:
            nd = parse_natspec(base)
    return nd


# --------------------------------------------------------------------------- types

def short_type(type_name) -> str:
    s = (type_name or {}).get("typeDescriptions", {}).get("typeString", "")
    for prefix in ("struct ", "enum ", "contract ", "interface "):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    if "." in s and "(" not in s and " " not in s:  # ILidoLendMarketController.HookEvent -> HookEvent
        s = s.rsplit(".", 1)[-1]
    return s


def render_param(v: dict) -> str:
    parts = [short_type(v.get("typeName"))]
    if v.get("storageLocation") in ("memory", "calldata", "storage"):
        parts.append(v["storageLocation"])
    if v.get("name"):
        parts.append(v["name"])
    return " ".join(parts)


def function_signature(fn: dict) -> str:
    params = [render_param(p) for p in fn["parameters"]["parameters"]]
    kind = fn.get("kind")
    if kind == "constructor":
        head, tail = "constructor", ""
    else:
        head = kind if kind in ("fallback", "receive") else f"function {fn.get('name', '')}"
        tail = ""
        if fn.get("visibility"):
            tail += f" {fn['visibility']}"
        if fn.get("stateMutability") in ("view", "pure", "payable"):
            tail += f" {fn['stateMutability']}"
        rets = fn["returnParameters"]["parameters"]
        if rets:
            tail += " returns (" + ", ".join(render_param(r) for r in rets) + ")"
    oneline = f"{head}({', '.join(params)}){tail};"
    if len(oneline) <= 80 or not params:  # wrap long signatures one parameter per line
        return oneline
    body = ",\n".join(f"    {p}" for p in params)
    return f"{head}(\n{body}\n){tail};"


def variable_declaration(v: dict) -> str:
    t = re.sub(r"\b(struct|enum|contract|interface)\s+", "", v["typeName"]["typeDescriptions"]["typeString"])
    parts = [t]
    if v.get("constant"):
        parts.append("constant")
    if v.get("visibility"):
        parts.append(v["visibility"])
    parts.append(v["name"])
    return " ".join(parts)


def struct_from_source(rel_path: str, name: str) -> dict:
    """A render_struct-compatible node for a file-scope struct solc emits no standalone artifact for
    (e.g. src/types/SettlementTypes.sol). Reads the leading `///` doc block and field list from source."""
    src = (ROOT / rel_path).read_text()
    m = re.search(r"((?:[ \t]*///.*\n)+)[ \t]*struct[ \t]+" + re.escape(name) + r"[ \t]*\{([^}]*)\}", src)
    if not m:
        sys.exit(f"struct {name} not found in {rel_path}")
    doc = "\n".join(re.sub(r"^[ \t]*///[ \t]?", "", ln) for ln in m.group(1).splitlines())
    members = [{"name": f.group(2), "typeName": {"typeDescriptions": {"typeString": f.group(1)}}}
               for f in re.finditer(r"([A-Za-z_][\w.\[\]]*)[ \t]+([A-Za-z_]\w*)[ \t]*;", m.group(2))]
    return {"name": name, "members": members, "documentation": {"text": doc}}


# --------------------------------------------------------------------------- markdown

def md_table(header, rows) -> list:
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    return out + ["| " + " | ".join(r) + " |" for r in rows]


def normalize(text: str) -> str:
    return re.sub(r"([.!?])([A-Z`])", r"\1 \2", text)  # space out abutting sentences if any


def render_block(text: str) -> list:
    """Format one natspec tag body as markdown: join soft-wrapped lines, keep `-` bullet lists,
    keep blank-line paragraph breaks."""
    items = []  # ('p' | 'li' | 'break', text)
    for ln in text.split("\n"):
        ln = ln.strip()
        if not ln:
            items.append(("break", ""))
        elif ln.startswith("- "):
            items.append(("li", ln[2:].strip()))
        elif items and items[-1][0] in ("p", "li"):  # continuation of a wrapped line
            items[-1] = (items[-1][0], (items[-1][1] + " " + ln).strip())
        else:
            items.append(("p", ln))
    out, prev = [], None
    for kind, txt in items:
        if kind == "break":
            prev = None
            continue
        txt = normalize(txt)
        if kind == "p" and re.match(r"(?i)warning\b\s*:?", txt):  # render a `Warning:` para as a GitHub alert
            body = re.sub(r"(?i)^warning\b\s*:?\s*", "", txt)
            if out and out[-1] != "":
                out.append("")
            out += ["> [!WARNING]", f"> {body}", ""]
            prev = None
            continue
        if out and (kind == "p" or prev == "p"):  # blank line before a paragraph or a list after one
            out.append("")
        out.append(f"- {txt}" if kind == "li" else txt)
        prev = kind
    return out


def paras(*texts) -> list:
    out = []
    for t in texts:
        if t:
            out += render_block(t) + [""]
    return out


def render_function(fn, reg, level) -> list:
    kind = fn.get("kind")
    name = kind if kind in ("constructor", "fallback", "receive") else fn.get("name", "")
    nd = resolve_doc(fn, reg)
    out = [f"{'#' * level} `{name}`", ""]
    out += ["```solidity", function_signature(fn), "```", ""]  # signature, then its parameter tables

    prows = [(f"`{p['name']}`", f"`{short_type(p['typeName'])}`", nd["params"].get(p["name"], ""))
             for p in fn["parameters"]["parameters"] if p.get("name")]
    if any(r[2].strip() for r in prows):
        out += ["**Parameters**", ""] + md_table(("Name", "Type", "Description"), prows) + [""]

    ret_descs = {}
    for entry in nd["returns"]:
        head, _, rest = entry.partition(" ")
        ret_descs[head] = rest
    rrows = []
    for i, r in enumerate(fn["returnParameters"]["parameters"]):
        if r.get("name"):
            name_cell = f"`{r['name']}`"
            desc = ret_descs.get(r["name"], "")
        else:  # unnamed return — match forge doc's `<none>`, keep the raw @return text as the description
            name_cell = "`<none>`"
            desc = nd["returns"][i] if i < len(nd["returns"]) else ""
        rrows.append((name_cell, f"`{short_type(r['typeName'])}`", desc))
    if any(r[2].strip() for r in rrows):
        out += ["**Returns**", ""] + md_table(("Name", "Type", "Description"), rrows) + [""]

    out += paras(nd["notice"], *nd["dev"])  # description and notes after the interface
    return out


def render_struct(node, level) -> list:
    nd = parse_natspec(doc_text(node))
    out = [f"{'#' * level} `{node['name']}`", ""]
    body = [f"    {short_type(m['typeName'])} {m['name']};" for m in node["members"]]
    out += ["```solidity", f"struct {node['name']} {{", *body, "}", "```", ""]
    out += paras(nd["notice"], *nd["dev"])
    rows = [(f"`{m['name']}`", f"`{short_type(m['typeName'])}`", nd["params"].get(m["name"], ""))
            for m in node["members"]]
    if any(r[2].strip() for r in rows):  # skip an all-blank table (e.g. forked structs with no field docs)
        out += ["**Fields**", ""] + md_table(("Name", "Type", "Description"), rows) + [""]
    return out


def render_enum(node, level) -> list:
    nd = parse_natspec(doc_text(node))
    out = [f"{'#' * level} `{node['name']}`", ""]
    body = ",\n".join(f"    {m['name']}" for m in node["members"])
    out += ["```solidity", f"enum {node['name']} {{", body, "}", "```", ""]
    out += paras(nd["notice"], *nd["dev"])
    return out


def member_signature(node, keyword) -> str:
    parts = []
    for p in node["parameters"]["parameters"]:
        seg = [short_type(p.get("typeName"))]
        if p.get("indexed"):
            seg.append("indexed")
        if p.get("name"):
            seg.append(p["name"])
        parts.append(" ".join(seg))
    return f"{keyword} {node['name']}({', '.join(parts)});"


def render_event_or_error(node, keyword, level) -> list:
    nd = parse_natspec(doc_text(node))
    out = [f"{'#' * level} `{node['name']}`", "", "```solidity", member_signature(node, keyword), "```", ""]
    prows = [(f"`{p['name']}`", f"`{short_type(p['typeName'])}`", nd["params"].get(p["name"], ""))
             for p in node["parameters"]["parameters"] if p.get("name")]
    if any(r[2].strip() for r in prows):
        out += ["**Parameters**", ""] + md_table(("Name", "Type", "Description"), prows) + [""]
    out += paras(nd["notice"], *nd["dev"])
    return out


def render_contract(rel, name, reg, level, extra_enums=(), extra_structs=(), extra_events=(), extra_errors=(),
                    extra_funcs=(), extra_statevars=(), bases=()) -> list:
    """Render a contract's members with types and events first, functions after. No entity heading — the
    page title (one level up) owns the name, so sections sit at `level` and members at `level + 1`.
    extra_enums/extra_structs/extra_events/extra_errors/extra_funcs/extra_statevars are members declared elsewhere
    (file-scope types, inherited members, or functions whose richer natspec lives on the concrete contract rather
    than the interface) folded into the sections.
    bases is a list of (rel, name) base interfaces whose members are merged in (a member declared on a Lido base
    interface the rendered one inherits is part of this contract's surface)."""
    node = find(ast_of(rel), "ContractDefinition", name)
    nd = parse_natspec(doc_text(node))  # contract-level natspec has no @inheritdoc
    out = list(paras(nd["notice"], *nd["dev"]))

    members = list(node["nodes"])
    for brel, bname in bases:
        members += find(ast_of(brel), "ContractDefinition", bname)["nodes"]
    statevars = [n for n in members if n.get("nodeType") == "VariableDeclaration"
                 and n.get("stateVariable") and n.get("visibility") == "public"] + list(extra_statevars)
    funcs = [n for n in members if n.get("nodeType") == "FunctionDefinition"
             and (n.get("kind") == "constructor" or n.get("visibility") in ("public", "external"))] + list(extra_funcs)
    enums = [n for n in members if n.get("nodeType") == "EnumDefinition"] + list(extra_enums)
    structs = [n for n in members if n.get("nodeType") == "StructDefinition"] + list(extra_structs)
    events = [n for n in members if n.get("nodeType") == "EventDefinition"] + list(extra_events)
    errors = [n for n in members if n.get("nodeType") == "ErrorDefinition"] + list(extra_errors)

    if enums:
        out += [f"{'#' * level} Enums", ""]
        for e in enums:
            out += render_enum(e, level + 1)

    if structs:
        out += [f"{'#' * level} Structs", ""]
        for s in structs:
            out += render_struct(s, level + 1)

    if events:
        out += [f"{'#' * level} Events", ""]
        for e in events:
            out += render_event_or_error(e, "event", level + 1)

    if errors:
        out += [f"{'#' * level} Errors", ""]
        for e in errors:
            out += render_event_or_error(e, "error", level + 1)

    if funcs:
        funcs = sorted(funcs, key=lambda f: 0 if f.get("kind") == "constructor" else 1)
        out += [f"{'#' * level} Functions", ""]
        for fn in funcs:
            out += render_function(fn, reg, level + 1)

    if statevars:
        out += [f"{'#' * level} State variables", ""]
        rows = []
        for v in statevars:
            vd = resolve_doc(v, reg)
            desc = " ".join(" ".join(t.split()) for t in [vd["notice"], *vd["dev"]] if t)
            typ = re.sub(r"\b(struct|enum|contract|interface)\s+", "", v["typeName"]["typeDescriptions"]["typeString"])
            mut = v.get("mutability")
            type_cell = f"`{typ}`" + (f" ({mut})" if mut in ("constant", "immutable") else "")
            rows.append((f"`{v['name']}`", type_cell, desc))
        out += md_table(("Name", "Type", "Description"), rows) + [""]
    return out


# --------------------------------------------------------------------------- assembly

API_DIR = ROOT / "docs" / "specs" / "api"
HEADER = "<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->"
ACCESS_CONTROL_NOTE = (
    "Standard inherited role-membership and role-administration functions are not repeated; see "
    "[OpenZeppelin AccessControlEnumerable]"
    "(https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable)."
)
ERC4626_NOTE = (
    "Standard inherited ERC-20 share-token and ERC-4626 vault functions are not repeated; see "
    "[ERC-4626](https://eips.ethereum.org/EIPS/eip-4626)."
)

VAULT = "LidoLendERC4626.sol/LidoLendERC4626.json"
VAULT_IFACE = "ILidoLendERC4626.sol/ILidoLendERC4626.json"
GUARDIAN = "IGuardianSignals.sol/IGuardianSignals.json"
GUARDIAN_VIEW = "IGuardianSignalsView.sol/IGuardianSignalsView.json"
GUARDIAN_TYPES = "GuardianSignalsTypes.sol/GuardianSignalsTypes.json"
WSTETH_ORACLE = "WstEthRateOracle.sol/WstEthRateOracle.json"
USDY_ORACLE = "UsdyStableOracle.sol/UsdyStableOracle.json"
NAV_ORACLE_BASE = "TrailingAnchorOracleBase.sol/TrailingAnchorOracleBase.json"
NAV_ORACLE_ADAPTERS = (
    ("UsdyNavOracle.sol/UsdyNavOracle.json", "UsdyNavOracle"),
    ("CentrifugeNavOracle.sol/CentrifugeNavOracle.json", "CentrifugeNavOracle"),
)
EXIT_BOOK_BASE = "IExitBook.sol/IExitBook.json"
EXIT_BOOK_4626 = "IErc4626ExitBook.sol/IErc4626ExitBook.json"
EXIT_BOOK_MORPHO = "IMorphoExitBook.sol/IMorphoExitBook.json"
DASHBOARD = "IRiskStewardDashboard.sol/IRiskStewardDashboard.json"
MARKET_FACTORY = "LidoLendMarketFactory.sol/LidoLendMarketFactory.json"
OWNER = "ILidoLendOwner.sol/ILidoLendOwner.json"
OWNER_C = "LidoLendOwner.sol/LidoLendOwner.json"
VAULT_ADAPTER = "LidoLendVaultAdapter.sol/LidoLendVaultAdapter.json"
ETHEREUM_ADAPTER = "EthereumGeneralAdapter1.sol/EthereumGeneralAdapter1.json"
OSSIFIABLE_PROXY = "OssifiableProxy.sol/OssifiableProxy.json"
EXIT_BOOK_BASE_C = "ExitBookBase.sol/ExitBookBase.json"
EXIT_BOOK_4626_C = "Erc4626ExitBook.sol/Erc4626ExitBook.json"
EXIT_BOOK_MORPHO_C = "MorphoExitBook.sol/MorphoExitBook.json"
EXIT_BOOK_TYPES = "ExitBookTypes.sol/ExitBookTypes.json"
EXIT_BOOK_LIB = "ExitBookLib.sol/ExitBookLib.json"
ASSET_RECOVERER = "AssetRecoverer.sol/AssetRecoverer.json"

def iface_members(rel, name, node_type):
    """Events and errors of a contract often live on its interface, not the contract itself. Pull them by node
    type from the interface artifact so the page that renders the contract still lists them."""
    node = find(ast_of(rel), "ContractDefinition", name)
    return [n for n in node["nodes"] if n.get("nodeType") == node_type]


def write_page(filename: str, title: str, body: list) -> str:
    API_DIR.mkdir(parents=True, exist_ok=True)
    text = "\n".join([HEADER, "", f"# {title}", ""] + body)
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
    (API_DIR / filename).write_text(text)
    return filename


def main() -> int:
    reg = build_registry([ast_of(CONTROLLER), ast_of(GUARDIAN), ast_of(EXIT_BOOK_BASE)])
    written = []

    # One file per contract, named in kebab-case after the contract it documents. The controller page folds in the
    # fork hook types (HookEvent + *HookData) and renders on/marketId from the concrete impl, which docs them richer.
    hook_enums = iface_members(BASE_CONTROLLER, "ILidoLendMarketController", "EnumDefinition")
    hook_structs = iface_members(BASE_CONTROLLER, "ILidoLendMarketController", "StructDefinition")
    activation_cfg = struct_from_source("src/types/CollateralActivationTypes.sol", "CollateralActivationConfig")
    hook_funcs = [f for f in iface_members(CONTROLLER_IMPL, "LidoLendMarketController", "FunctionDefinition")
                  if f["name"] in ("on", "marketId")]
    controller_body = [ACCESS_CONTROL_NOTE, ""] + render_contract(
        CONTROLLER, "ILidoLendMarketController", reg, BASE,
        bases=[(CONFIGURATOR, "ILidoLendMarketConfigurator")],
        extra_enums=hook_enums,
        extra_structs=hook_structs + [activation_cfg],
        extra_funcs=hook_funcs)
    written.append(write_page("lido-lend-market-controller.md", "LidoLendMarketController", controller_body))
    vault_events = iface_members(VAULT_IFACE, "ILidoLendERC4626", "EventDefinition")
    vault_errors = iface_members(VAULT_IFACE, "ILidoLendERC4626", "ErrorDefinition")
    vault_body = [ERC4626_NOTE, ""] + render_contract(
        VAULT, "LidoLendERC4626", reg, BASE, extra_events=vault_events, extra_errors=vault_errors)
    written.append(write_page("lido-lend-erc4626.md", "LidoLendERC4626", vault_body))

    gt = ast_of(GUARDIAN_TYPES)
    gbody = [ACCESS_CONTROL_NOTE, ""] + render_contract(GUARDIAN, "IGuardianSignals", reg, BASE,
                            bases=[(GUARDIAN_VIEW, "IGuardianSignalsView")],
                            extra_structs=[find(gt, "StructDefinition", s)
                                           for s in ("BlockInfoWithHash", "GuardiansOpinion")])
    written.append(write_page("guardian-signals.md", "GuardianSignals", gbody))

    # The lender exit-book layer: an abstract base plus two source-specific concrete books.
    exit_body = ["The lender exit-book layer. An abstract `ExitBookBase` holds the shared fill, cancel, and "
                 "fee surface, and a concrete book binds it to a source — `Erc4626ExitBook` over a vault, "
                 "`MorphoExitBook` over a market. Standard inherited `AccessControlEnumerable` surface is not "
                 "repeated here. On Exit Books, every recovery function requires `RECOVERER_ROLE`.", ""]
    ebt = ast_of(EXIT_BOOK_TYPES)
    exit_base = find(ast_of(EXIT_BOOK_BASE_C), "ContractDefinition", "ExitBookBase")
    exit_lib = find(ast_of(EXIT_BOOK_LIB), "ContractDefinition", "ExitBookLib")
    recoverer = find(ast_of(ASSET_RECOVERER), "ContractDefinition", "AssetRecoverer")
    recoverer_funcs = [n for n in recoverer["nodes"] if n.get("nodeType") == "FunctionDefinition"
                       and n.get("visibility") in ("public", "external")]
    base_statevar_names = {
        "ALLOWLIST_MANAGER_ROLE", "FEE_MANAGER_ROLE", "RECOVERER_ROLE", "MAX_PRIORITY_FEE", "MAX_SERVICE_FEE",
        "MAX_REQUEST_LIFETIME", "feeRecipient", "serviceFee"
    }
    base_statevars = [n for n in exit_base["nodes"] if n.get("nodeType") == "VariableDeclaration"
                      and n.get("name") in base_statevar_names]
    exit_body += [f"{'#' * BASE} ExitBookBase", ""] + render_contract(
        EXIT_BOOK_BASE, "IExitBook", reg, BASE + 1,
        extra_enums=[find(ebt, "EnumDefinition", "ExitStatus")],
        extra_structs=[find(ebt, "StructDefinition", s) for s in ("PriorityRamp", "Request")],
        extra_events=(iface_members(EXIT_BOOK_BASE_C, "ExitBookBase", "EventDefinition")
                      + [n for n in recoverer["nodes"] if n.get("nodeType") == "EventDefinition"]),
        extra_errors=(iface_members(EXIT_BOOK_BASE_C, "ExitBookBase", "ErrorDefinition")
                      + [n for n in exit_lib["nodes"] if n.get("nodeType") == "ErrorDefinition"]
                      + [n for n in recoverer["nodes"] if n.get("nodeType") == "ErrorDefinition"]),
        extra_funcs=recoverer_funcs,
        extra_statevars=base_statevars)
    erc4626_constructor = next(n for n in find(ast_of(EXIT_BOOK_4626_C), "ContractDefinition", "Erc4626ExitBook")["nodes"]
                               if n.get("nodeType") == "FunctionDefinition" and n.get("kind") == "constructor")
    exit_body += [f"{'#' * BASE} Erc4626ExitBook", ""] + render_contract(
        EXIT_BOOK_4626, "IErc4626ExitBook", reg, BASE + 1,
        extra_events=iface_members(EXIT_BOOK_4626_C, "Erc4626ExitBook", "EventDefinition"),
        extra_errors=iface_members(EXIT_BOOK_4626_C, "Erc4626ExitBook", "ErrorDefinition"),
        extra_funcs=[erc4626_constructor])
    morpho_constructor = next(n for n in find(ast_of(EXIT_BOOK_MORPHO_C), "ContractDefinition", "MorphoExitBook")["nodes"]
                              if n.get("nodeType") == "FunctionDefinition" and n.get("kind") == "constructor")
    exit_body += [f"{'#' * BASE} MorphoExitBook", ""] + render_contract(
        EXIT_BOOK_MORPHO, "IMorphoExitBook", reg, BASE + 1,
        extra_events=iface_members(EXIT_BOOK_MORPHO_C, "MorphoExitBook", "EventDefinition"),
        extra_errors=iface_members(EXIT_BOOK_MORPHO_C, "MorphoExitBook", "ErrorDefinition"),
        extra_funcs=[morpho_constructor])
    written.append(write_page("exit-book.md", "Exit Books", exit_body))

    dashboard_body = [ACCESS_CONTROL_NOTE, ""] + render_contract(
        DASHBOARD, "IRiskStewardDashboard", reg, BASE)
    written.append(write_page("risk-steward-dashboard.md", "RiskStewardDashboard", dashboard_body))

    written.append(write_page("lido-lend-market-factory.md", "LidoLendMarketFactory",
                              render_contract(MARKET_FACTORY, "LidoLendMarketFactory", reg, BASE)))

    owner_constructor = [n for n in find(ast_of(OWNER_C), "ContractDefinition", "LidoLendOwner")["nodes"]
                         if n.get("nodeType") == "FunctionDefinition" and n.get("kind") == "constructor"]
    owner_body = [ACCESS_CONTROL_NOTE, ""]
    owner_body += render_contract(OWNER, "ILidoLendOwner", reg, BASE, extra_funcs=owner_constructor)
    written.append(write_page("lido-lend-owner.md", "LidoLendOwner", owner_body))

    adapter_body = ["The local Bundler3 integration surface. Every non-constructor action below is callable only by "
                    "the configured Bundler3 contract. Standard inherited Bundler3 adapter functions are documented "
                    "by [Bundler3](https://github.com/morpho-org/bundler3) and are not repeated here.", ""]
    adapter_body += [f"{'#' * BASE} LidoLendVaultAdapter", ""] + render_contract(
        VAULT_ADAPTER, "LidoLendVaultAdapter", reg, BASE + 1)
    adapter_body += [f"{'#' * BASE} EthereumGeneralAdapter1", ""] + render_contract(
        ETHEREUM_ADAPTER, "EthereumGeneralAdapter1", reg, BASE + 1)
    written.append(write_page("bundler3-adapters.md", "Bundler3 Adapters", adapter_body))

    proxy_body = ["This page covers the local proxy-admin extension. Standard inherited ERC-1967 proxy surface, "
                  "including the delegated calldata fallback, is not repeated. The ossify, change-admin, and upgrade "
                  "methods require the current nonzero proxy admin; after ossification they remain permanently "
                  "unavailable.", ""]
    proxy_body += render_contract(OSSIFIABLE_PROXY, "OssifiableProxy", reg, BASE)
    written.append(write_page("ossifiable-proxy.md", "OssifiableProxy", proxy_body))

    written.append(write_page("wst-eth-rate-oracle.md", "WstEthRateOracle",
                              render_contract(WSTETH_ORACLE, "WstEthRateOracle", reg, BASE)))
    written.append(write_page("usdy-stable-oracle.md", "UsdyStableOracle",
                              render_contract(USDY_ORACLE, "UsdyStableOracle", reg, BASE)))

    # The NAV oracle family: every rule lives in the abstract base, each adapter adds its source and its scaling.
    nav_body = ["The NAV oracle family. `TrailingAnchorOracleBase` holds every rule and each adapter binds one source "
                "and overrides only how it is read. The mechanism, its invariants and its calibration are specified in "
                "[Trailing Anchor Oracle](../trailing-anchor-oracle.md).", "", ACCESS_CONTROL_NOTE, ""]
    nav_body += [f"{'#' * BASE} TrailingAnchorOracleBase", ""] + render_contract(
        NAV_ORACLE_BASE, "TrailingAnchorOracleBase", reg, BASE + 1)
    for rel, name in NAV_ORACLE_ADAPTERS:
        nav_body += [f"{'#' * BASE} {name}", ""] + render_contract(rel, name, reg, BASE + 1)
    written.append(write_page("nav-oracle.md", "NAV Oracle", nav_body))

    # Shared types: Id/MarketParams/Position are forked Morpho core (defer detail to the fork). The settlement types
    # are ours and are parsed from source because their file emits no standalone artifact.
    tbody = ["The core market types (`Id`, `MarketParams`, `Position`) belong to the forked Morpho core — their "
             "full semantics live in the [Lido Lend specification]"
             "(https://github.com/lidofinance/lido-lend/blob/main/SPECIFICATION.md).", ""]
    id_node = find(ast_of(IMORPHO), "UserDefinedValueTypeDefinition", "Id")
    tbody += [f"{'#' * BASE} `Id`", "",
              "```solidity", f"type Id is {id_node['underlyingType']['typeDescriptions']['typeString']}", "```", "",
              ID_FALLBACK, ""]
    for s in ("MarketParams", "Position"):
        tbody += render_struct(find(ast_of(IMORPHO), "StructDefinition", s), BASE)
    for s in ("SettlementSlice", "SettlementQuote", "SettlementConfig"):
        tbody += render_struct(struct_from_source("src/types/SettlementTypes.sol", s), BASE)
    written.append(write_page("shared-types.md", "Shared Types", tbody))

    for stale in sorted(API_DIR.glob("*.md")):  # drop pages left by earlier names
        if stale.name not in written:
            stale.unlink()

    print(f"generated {len(written)} API pages under {API_DIR.relative_to(ROOT)}: " + ", ".join(written))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
