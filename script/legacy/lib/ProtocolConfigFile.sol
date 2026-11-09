// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ArtifactMetadataFile} from "./ArtifactMetadata.sol";

/// @notice Paths used by historical activation rehearsals.
library ProtocolConfigFile {
    function protocolPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/protocol.toml");
    }

    function marketsDir() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/markets");
    }

    function exitBooksPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/exit-books.toml");
    }
}
