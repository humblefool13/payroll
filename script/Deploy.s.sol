// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {PayrollFactory} from "../src/PayrollFactory.sol";

contract Deploy is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // Optional: initial fee in bps (defaults to 0 if not set)
        uint256 initialFeeBps = vm.envOr("INITIAL_FEE_BPS", uint256(0));

        // Optional: comma-separated whitelisted token addresses beyond ETH
        // e.g. WHITELIST_TOKENS=0xdAC17F958D2ee523a2206206994597C13D831ec7,0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        string memory tokenList = vm.envOr("WHITELIST_TOKENS", string(""));

        vm.startBroadcast(deployerKey);

        PayrollFactory factory = new PayrollFactory(deployer);
        console.log("PayrollFactory deployed at:", address(factory));

        if (initialFeeBps > 0) {
            factory.setFeeBps(initialFeeBps);
            console.log("Fee set to (bps):", initialFeeBps);
        }

        // Parse and whitelist tokens if provided
        if (bytes(tokenList).length > 0) {
            address[] memory tokens = _parseAddresses(tokenList);
            for (uint256 i = 0; i < tokens.length; i++) {
                factory.whitelistToken(tokens[i]);
                console.log("Whitelisted token:", tokens[i]);
            }
        }

        vm.stopBroadcast();
    }

    /// @dev Minimal comma-separated address parser for up to 20 tokens.
    function _parseAddresses(string memory input) internal pure returns (address[] memory) {
        bytes memory b = bytes(input);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = b[j];
                }
                result[idx++] = _parseAddress(string(slice));
                start = i + 1;
            }
        }
        return result;
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42 && b[0] == "0" && b[1] == "x", "invalid address");
        uint160 addr = 0;
        for (uint256 i = 2; i < 42; i++) {
            addr *= 16;
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) addr += c - 48;
            else if (c >= 65 && c <= 70) addr += c - 55;
            else if (c >= 97 && c <= 102) addr += c - 87;
            else revert("invalid hex char");
        }
        return address(addr);
    }
}
