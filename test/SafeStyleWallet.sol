// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal stand-in for a Safe (Gnosis Safe) smart wallet, used to test that native token payouts reach it.
//
// What makes a Safe awkward to pay is its shape, and that is what these two contracts reproduce:
// 1. The wallet address is a thin proxy. Every call, including a plain native token transfer, reads the
//    singleton address from storage slot 0 and delegatecalls it.
// 2. The singleton's receive() emits SafeReceived(sender, value).
//
// On a fresh transaction that costs roughly 2100 (cold SLOAD) + 2600 (cold DELEGATECALL target) + 1381 (LOG2
// with one data word) plus small change, about 6.3k gas. That is far more than the 2300 stipend of
// .transfer / .send, which is why Safes can't be paid that way.
//
// Owner management is cut down to a single owner and execTransaction takes no signatures. None of that is on
// the receive path.

contract SafeStyleSingleton {
	address internal singleton; // slot 0 is reserved for the proxy, exactly as in a Safe
	address public owner;

	event SafeReceived(address indexed sender, uint256 value);

	constructor() {
		// lock the singleton itself so it can only be used through proxies
		owner = address(1);
	}

	function setup(address _owner) external {
		require(owner == address(0), "already set up");
		require(_owner != address(0), "owner is zero");
		owner = _owner;
	}

	// Simplified execTransaction: the single owner calls it directly instead of supplying signatures.
	// Reverts from the target bubble up unchanged.
	function execTransaction(address to, uint256 value, bytes calldata data) external payable returns (bytes memory returnData) {
		require(msg.sender == owner, "only owner can execute");
		bool success;
		(success, returnData) = to.call{value: value}(data);
		if (!success) {
			assembly {
				revert(add(returnData, 0x20), mload(returnData))
			}
		}
	}

	receive() external payable {
		emit SafeReceived(msg.sender, msg.value);
	}
}

contract SafeStyleProxy {
	address internal singleton; // must stay the first variable so it sits in slot 0

	constructor(address _singleton) {
		require(_singleton != address(0), "singleton is zero");
		singleton = _singleton;
	}

	// Forward everything to the singleton, the same way a Safe proxy does
	fallback() external payable {
		assembly {
			let target := and(sload(0), 0xffffffffffffffffffffffffffffffffffffffff)
			// masterCopy() is answered by the proxy itself
			if eq(calldataload(0), 0xa619486e00000000000000000000000000000000000000000000000000000000) {
				mstore(0, target)
				return(0, 0x20)
			}
			calldatacopy(0, 0, calldatasize())
			let success := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
			returndatacopy(0, 0, returndatasize())
			if iszero(success) {
				revert(0, returndatasize())
			}
			return(0, returndatasize())
		}
	}
}
