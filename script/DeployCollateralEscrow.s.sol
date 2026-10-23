// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";

contract DeployCollateralEscrow is Script {
    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN_ADDRESS");
        address attester = vm.envAddress("ATTESTER_ADDRESS");
        uint256 perAttestationCap = vm.envUint("ESCROW_PER_ATTESTATION_CAP");
        uint256 dailyReleaseLimit = vm.envUint("ESCROW_DAILY_RELEASE_LIMIT");
        uint256 maxAttestationTtl = vm.envUint("ESCROW_MAX_ATTESTATION_TTL");

        vm.startBroadcast();
        CollateralEscrow escrow = new CollateralEscrow(
            owner, collateralToken, attester, perAttestationCap, dailyReleaseLimit, maxAttestationTtl
        );
        vm.stopBroadcast();

        console2.log("Escrow:", address(escrow));
        console2.log("Final owner:", escrow.owner());
        console2.log("Collateral token:", collateralToken);
        console2.log("Attester:", attester);
        console2.log("Seizure is unavailable in this contract.");
    }
}
