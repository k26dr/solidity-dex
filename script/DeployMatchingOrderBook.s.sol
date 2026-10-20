// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
 
import {Script, console} from "forge-std/Script.sol";
import {MatchingOrderBook} from "../MatchingOrderBook.sol";
 
// Optional env vars:
//   PROTOCOL_FEE_RECEIVER  address that receives the protocol fee (default: the deployer)
//   PROTOCOL_FEE_PERCENT   protocol fee as a percent of each market fee, max 50 (default: 50)
// The receiver can lower the percent later with updateProtocolFee.
// Deploying with PROTOCOL_FEE_RECEIVER=0x0000000000000000000000000000000000000000 and percent 0 disables the protocol fee permanently.
contract DeployScript is Script {
    function run() public returns (MatchingOrderBook book) {
        address payable protocolFeeReceiver = payable(vm.envOr("PROTOCOL_FEE_RECEIVER", msg.sender));
        uint protocolFeePercent = vm.envOr("PROTOCOL_FEE_PERCENT", uint(50));

        vm.startBroadcast();
        book = new MatchingOrderBook(protocolFeeReceiver, protocolFeePercent);
        vm.stopBroadcast();

        console.log("MatchingOrderBook deployed at", address(book));
        console.log("protocol fee receiver", protocolFeeReceiver);
        console.log("protocol fee percent", protocolFeePercent);
    }
}
