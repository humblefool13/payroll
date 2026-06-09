// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {PayrollFactory} from "../src/PayrollFactory.sol";

contract Deploy is Script {
    // Salt mined to produce 0xB0b0B0B0... vanity address for deployer 0x7E193027A78eD1FC92df6f462f3260bcb3317E34.
    bytes32 constant SALT =
        0x5d1cb6f92e64ce8a038dd321dd56c9c6bddeb7a288b59124028af8af301a9bcb;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // Optional: initial fee in bps (defaults to 0 if not set)
        uint256 initialFeeBps = vm.envOr("INITIAL_FEE_BPS", uint256(0));

        // Optional: comma-separated whitelisted token addresses beyond ETH
        string memory tokenList = vm.envOr("WHITELIST_TOKENS", string(""));

        vm.startBroadcast(deployerKey);

        bytes memory initCode = abi.encodePacked(
            type(PayrollFactory).creationCode,
            abi.encode(deployer)
        );
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(
            abi.encodePacked(SALT, initCode)
        );
        require(ok, "CREATE2 deployment failed");
        require(ret.length == 20, "unexpected return length");
        address factoryAddr;
        assembly {
            factoryAddr := shr(96, mload(add(ret, 32)))
        }
        require(
            factoryAddr == 0xB0b0B0b0561Ff8Be504787aF00C611f9a9Bd6EFa,
            "unexpected address"
        );

        PayrollFactory factory = PayrollFactory(factoryAddr);
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
    function _parseAddresses(
        string memory input
    ) internal pure returns (address[] memory) {
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
        require(
            b.length == 42 && b[0] == "0" && b[1] == "x",
            "invalid address"
        );
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
