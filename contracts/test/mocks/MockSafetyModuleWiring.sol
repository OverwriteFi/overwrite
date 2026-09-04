// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISafetyModuleWiring} from "../../src/interfaces/IEmissionsController.sol";

/// @dev A stand-in sink with settable back-references, so `EmissionsController.setSink`'s two `Miswired`
/// branches can each be reached on their own. The real SafetyModule always answers correctly, which is why
/// the guard is otherwise unreachable from a test.
contract MockSafetyModuleWiring is ISafetyModuleWiring {
    address public emissions;
    address public writeToken;

    constructor(address emissions_, address write_) {
        emissions = emissions_;
        writeToken = write_;
    }
}
