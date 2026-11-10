// Shared CVL model of ERC20: calls answer from ghost balances, allowances, total supply and decimals;
// setupERC20() assumes balances sum to total supply. Each token has seven accounts, none address(0), so a
// caller pins every account it reads; pinning a possibly zero key deletes that execution.

definition MAX_ERC20_USERS() returns mathint = 7;

methods {
    function _.balanceOf(address account) external
        => balanceOfERC20CVL(calledContract, account) expect uint256 UNRESOLVED;
    // Backstop with no live caller: the only in-scope reader sits in the vault's DELETEd initializer.
    function _.decimals() external
        => ghostERC20Decimals8[calledContract] expect uint8 UNRESOLVED;
    function _.totalSupply() external
        => require_uint256(ghostERC20TotalSupply256[calledContract]) expect uint256 UNRESOLVED;
    function _.approve(address spender, uint256 amount) external with (env e)
        => approveERC20CVL(calledContract, e.msg.sender, spender, amount) expect bool UNRESOLVED;
    function _.transfer(address to, uint256 amount) external with (env e)
        => transferERC20CVL(calledContract, e.msg.sender, to, amount) expect bool UNRESOLVED;
    function _.transferFrom(address from, address to, uint256 amount) external with (env e)
        => transferFromERC20CVL(calledContract, e.msg.sender, from, to, amount) expect bool UNRESOLVED;
    function _.allowance(address owner, address spender) external
        => require_uint256(ghostERC20Allowances256[calledContract][owner][spender]) expect uint256 UNRESOLVED;
}

definition ERC20_ACCOUNT_BOUNDS(address token, address account) returns bool =
    ghostERC20AccountsValues[token][0] == account
    || ghostERC20AccountsValues[token][1] == account
    || ghostERC20AccountsValues[token][2] == account
    || ghostERC20AccountsValues[token][3] == account
    || ghostERC20AccountsValues[token][4] == account
    || ghostERC20AccountsValues[token][5] == account
    || ghostERC20AccountsValues[token][6] == account
    ;

// Keys of the ledger mirror: a modelled holder, or address(0), which is a key but never a member.
definition ERC20_ACCOUNT_BOUNDS_OR_ZERO(address token, address account) returns bool =
    account == 0 || ERC20_ACCOUNT_BOUNDS(token, account);

definition ERC20_TOTAL_SUPPLY_SOLVENCY() returns bool =
    forall address token.
        ghostERC20TotalSupply256[token]
            == ghostERC20Balances128[token][ghostERC20AccountsValues[token][0]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][1]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][2]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][3]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][4]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][5]]
            + ghostERC20Balances128[token][ghostERC20AccountsValues[token][6]];

// UNSAFE: token participants restricted to MAX_ERC20_USERS() distinct slots; flows touching more accounts are unanalyzed
persistent ghost ghostERC20Accounts(address, mathint) returns address {
    axiom forall address token. forall mathint i. forall mathint j.
        i >= 0 && i < MAX_ERC20_USERS()
            && j >= 0 && j < MAX_ERC20_USERS()
            && i != j
        => ghostERC20Accounts(token, i) != ghostERC20Accounts(token, j);
}

persistent ghost mapping(address => mapping(mathint => address)) ghostERC20AccountsValues {
    // SAFE: mapping mirror of the account-set UF (definitions cannot apply a UF).
    axiom forall address token. forall mathint i.
        ghostERC20AccountsValues[token][i] == ghostERC20Accounts(token, i);
    // SCOPE: address(0) is not a holder, so ERC20_ACCOUNT_BOUNDS(token, 0) is identically false.
    axiom forall address token. forall mathint i.
        (i >= 0 && i < MAX_ERC20_USERS()) => ghostERC20AccountsValues[token][i] != 0;
}

persistent ghost mapping(address => uint8) ghostERC20Decimals8 {
    // UNSAFE: decimals narrowed to [6,18]; tokens outside the band (and the offsets they imply) are unanalyzed
    axiom forall address token.
        ghostERC20Decimals8[token] >= 6 && ghostERC20Decimals8[token] <= 18;
}

persistent ghost mapping(address => mapping(address => mathint)) ghostERC20Balances128 {
    init_state axiom forall address token. forall address account.
        ghostERC20Balances128[token][account] == 0;
    // UNSAFE: balances capped at max_uint128 to keep summed flows overflow-free.
    axiom forall address token. forall address account.
        ghostERC20Balances128[token][account] >= 0
        && ghostERC20Balances128[token][account] <= max_uint128;
}

persistent ghost mapping(address => mapping(address => mapping(address => mathint))) ghostERC20Allowances256 {
    init_state axiom forall address token. forall address owner. forall address spender.
        ghostERC20Allowances256[token][owner][spender] == 0;
    axiom forall address token. forall address owner. forall address spender.
        ghostERC20Allowances256[token][owner][spender] >= 0
        && ghostERC20Allowances256[token][owner][spender] <= max_uint256;
}

persistent ghost mapping(address => mathint) ghostERC20TotalSupply256 {
    init_state axiom forall address token. ghostERC20TotalSupply256[token] == 0;
    axiom forall address token.
        ghostERC20TotalSupply256[token] >= 0 && ghostERC20TotalSupply256[token] <= max_uint256;
}

function setupERC20() {
    require(ERC20_TOTAL_SUPPLY_SOLVENCY(),
        "SAFE: balances sum to total supply");
}

function balanceOfERC20CVL(address token, address account) returns uint256 {
    require(token != 0, "ASSERT: zero-address token has no code");
    require(ERC20_ACCOUNT_BOUNDS(token, account),
        "UNSAFE: balances only for the 7 modelled accounts");
    return require_uint256(ghostERC20Balances128[token][account]);
}

function approveERC20CVL(address token, address owner, address spender, uint256 amount) returns bool {
    require(token != 0, "ASSERT: zero-address token has no code");
    require(ERC20_ACCOUNT_BOUNDS(token, owner) && ERC20_ACCOUNT_BOUNDS(token, spender),
        "UNSAFE: approvals only between the 7 modelled accounts");
    ghostERC20Allowances256[token][owner][spender] = amount;
    return true;
}

function transferERC20CVL(address token, address from, address to, uint256 amount) returns bool {
    require(token != 0, "ASSERT: zero-address token has no code");
    require(ERC20_ACCOUNT_BOUNDS(token, from) && ERC20_ACCOUNT_BOUNDS(token, to),
        "UNSAFE: transfers only between the 7 modelled accounts");
    require(ghostERC20Balances128[token][from] >= to_mathint(amount), "ASSERT: InsufficientBalance");
    ghostERC20Balances128[token][from] = ghostERC20Balances128[token][from] - amount;
    ghostERC20Balances128[token][to] = ghostERC20Balances128[token][to] + amount;
    return true;
}

function transferFromERC20CVL(address token, address spender, address from, address to, uint256 amount) returns bool {
    require(token != 0, "ASSERT: zero-address token has no code");
    require(ERC20_ACCOUNT_BOUNDS(token, from) && ERC20_ACCOUNT_BOUNDS(token, to),
        "UNSAFE: pulls only between the 7 modelled accounts");
    require(ghostERC20Allowances256[token][from][spender] == max_uint256
        || ghostERC20Allowances256[token][from][spender] >= to_mathint(amount),
        "ASSERT: InsufficientAllowance");
    if (ghostERC20Allowances256[token][from][spender] != max_uint256) {
        ghostERC20Allowances256[token][from][spender] =
            ghostERC20Allowances256[token][from][spender] - amount;
    }
    require(ghostERC20Balances128[token][from] >= to_mathint(amount), "ASSERT: InsufficientBalance");
    ghostERC20Balances128[token][from] = ghostERC20Balances128[token][from] - amount;
    ghostERC20Balances128[token][to] = ghostERC20Balances128[token][to] + amount;
    return true;
}
