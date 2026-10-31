// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../MatchingOrderBook.sol";

// Trader contract that tries to re-enter the order book whenever it receives native token.
// Bank.withdrawTo pays native token with a raw call, so the hook is receive() rather than a token callback.
// Built for a native base market (address(0) base), so every native payout to this contract is base token.
contract ReentrantNativeReceiver {
	enum Attack {
		NONE,
		PLACE_ORDER,             // try to sell the ETH it was just paid straight back into the book
		CANCEL_ORDER,            // try to cancel another of its own orders mid-payout
		WITHDRAW_FAILED_PAYMENT, // try to withdraw the parked balance a second time
		SWALLOWED_PLACE_ORDER    // like PLACE_ORDER but catch the revert so the payout itself succeeds
	}

	MatchingOrderBook immutable orderBook;
	bytes32 immutable marketId;
	address payable immutable bank;
	Attack public attack;
	uint128 public targetOrderId;
	uint public blockedReentries;

	constructor(MatchingOrderBook _orderBook, bytes32 _marketId) {
		orderBook = _orderBook;
		marketId = _marketId;
		bank = _orderBook.getMarketDetails(_marketId).bankAddress;
	}

	function setAttack(Attack _attack) external {
		attack = _attack;
	}

	function setTargetOrderId(uint128 _orderId) external {
		targetOrderId = _orderId;
	}

	function approve(address token) external {
		IERC20(token).approve(address(orderBook), type(uint256).max);
	}

	function placeOrder(MatchingOrderBook.Side side, uint baseQuantity, uint price) external payable returns (uint128) {
		return orderBook.placeOrder{value: msg.value}(marketId, side, baseQuantity, price, address(0));
	}

	function cancelOrder(MatchingOrderBook.Side side, uint128 orderId) external {
		orderBook.cancelOrder(marketId, side, orderId);
	}

	function withdrawFailedPayment() external {
		orderBook.withdrawFailedPayment(bank, address(0));
	}

	receive() external payable {
		if (attack == Attack.PLACE_ORDER) {
			orderBook.placeOrder{value: msg.value}(marketId, MatchingOrderBook.Side.SELL, msg.value, 1, address(0));
		} else if (attack == Attack.CANCEL_ORDER) {
			orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, targetOrderId);
		} else if (attack == Attack.WITHDRAW_FAILED_PAYMENT) {
			orderBook.withdrawFailedPayment(bank, address(0));
		} else if (attack == Attack.SWALLOWED_PLACE_ORDER) {
			try orderBook.placeOrder{value: msg.value}(marketId, MatchingOrderBook.Side.SELL, msg.value, 1, address(0)) {}
			catch Error(string memory reason) {
				if (keccak256(bytes(reason)) == keccak256("malicious attack")) blockedReentries++;
			}
		}
	}
}
