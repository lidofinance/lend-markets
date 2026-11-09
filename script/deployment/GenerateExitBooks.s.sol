// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {DeploymentArtifact} from "./DeploymentArtifact.sol";
import {ExitBooksRecord, DeploymentSchema} from "./DeploymentRecord.sol";
import {ExitBookAddresses} from "./DeploymentTypes.sol";
import {ArtifactMetadataFile} from "../legacy/lib/ArtifactMetadata.sol";

/// @notice Exports recorded exit books without requiring a protocol or market artifact.
contract GenerateExitBooks is Script {
    function run(string memory runName) external returns (string memory output) {
        string memory runDir = ArtifactMetadataFile.artifactsDir(runName);
        string memory artifact = vm.readFile(string.concat(runDir, "/exit-books.toml"));
        ExitBookAddresses memory books;
        if (vm.keyExistsToml(artifact, ".header.version")) {
            ExitBooksRecord memory record = abi.decode(
                DeploymentArtifact.read(
                    string.concat(runDir, "/exit-books.toml"), runName, "exit-books", DeploymentSchema.EXITBOOKSRECORD
                ),
                (ExitBooksRecord)
            );
            books = record.addresses;
            require(books.chainId == record.header.chainId, "Exit books chain mismatch");
        } else {
            require(
                keccak256(bytes(vm.parseTomlString(artifact, ".artifact.deployment"))) == keccak256(bytes(runName)),
                "Exit books identity differs from selected run"
            );
            books.chainId = vm.parseTomlUint(artifact, ".artifact.chain_id");
            books.morpho = vm.parseTomlAddress(artifact, ".exit_books.morpho");
            books.erc4626 = vm.parseTomlAddress(artifact, ".exit_books.erc4626");
        }
        string memory source = string.concat(
            "// SPDX-License-Identifier: GPL-2.0-or-later\npragma solidity 0.8.36;\n\n",
            'import {ExitBookAddresses} from "../../DeploymentTypes.sol";\n\n',
            "// Generated from ",
            runDir,
            "; regenerate instead of editing addresses.\n",
            "abstract contract ExitBooks {\n",
            "    function _exitBooks() internal pure returns (ExitBookAddresses memory books) {\n",
            "        books.chainId = ",
            vm.toString(books.chainId),
            ";\n",
            "        books.morpho = ",
            vm.toString(books.morpho),
            ";\n",
            "        books.erc4626 = ",
            vm.toString(books.erc4626),
            ";\n",
            "    }\n}\n"
        );
        string memory directory = string.concat("script/deployment/generated/", runName);
        vm.createDir(directory, true);
        output = string.concat(directory, "/ExitBooks.sol");
        vm.writeFile(output, source);
    }
}
