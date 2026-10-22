// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../MatchingOrderBook.sol";

interface ITransferReceiver {
	function onTransferReceived(address operator, address from, uint256 value, bytes calldata data) external returns (bytes4);
}

// ERC20 mock with an ERC1363-style receiver hook that fires on every transfer, not only transferAndCall.
// If the recipient is a contract its onTransferReceived is called. Recipients without the hook (empty revert) are ignored,
// but any revert with a reason is bubbled up so a malicious receiver can abort the transfer.
contract PayableERC20 {
	string public name;
	string public symbol;
	uint8 public immutable decimals;
	uint256 public totalSupply;

	mapping(address => uint256) public balanceOf;
	mapping(address => mapping(address => uint256)) public allowance;

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	constructor(string memory _name, string memory _symbol, uint8 _decimals) {
		name = _name;
		symbol = _symbol;
		decimals = _decimals;
	}

	function transfer(address to, uint256 amount) external returns (bool) {
		_transfer(msg.sender, to, amount);
		return true;
	}

	function approve(address spender, uint256 amount) external returns (bool) {
		allowance[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function transferFrom(address from, address to, uint256 amount) external returns (bool) {
		uint256 allowed = allowance[from][msg.sender];
		require(allowed >= amount, "ERC20: insufficient allowance");
		if (allowed != type(uint256).max) {
			allowance[from][msg.sender] = allowed - amount;
			emit Approval(from, msg.sender, allowance[from][msg.sender]);
		}
		_transfer(from, to, amount);
		return true;
	}

	function mint(address to, uint256 amount) external {
		require(to != address(0), "ERC20: mint to zero address");
		totalSupply += amount;
		balanceOf[to] += amount;
		emit Transfer(address(0), to, amount);
	}

	function _transfer(address from, address to, uint256 amount) internal {
		require(to != address(0), "ERC20: transfer to zero address");
		uint256 fromBal = balanceOf[from];
		require(fromBal >= amount, "ERC20: transfer amount exceeds balance");
		unchecked {
			balanceOf[from] = fromBal - amount;
			balanceOf[to] += amount;
		}
		emit Transfer(from, to, amount);

		if (to.code.length > 0) {
			try ITransferReceiver(to).onTransferReceived(msg.sender, from, amount, "") returns (bytes4) {}
			catch (bytes memory reason) {
				if (reason.length > 0) {
					assembly { revert(add(reason, 32), mload(reason)) }
				}
			}
		}
	}
}

// Trader contract that tries to re-enter the order book whenever it receives PayableERC20 tokens
contract ReentrantReceiver is ITransferReceiver {
	enum Attack {
		NONE,
		PLACE_ORDER,
		CANCEL_ORDER,
		WITHDRAW_FAILED_PAYMENT,
		CREATE_MARKET,
		BURN_GAS
	}

	MatchingOrderBook orderBook;
	bytes32 marketId;
	Attack public attack;

	constructor(MatchingOrderBook _orderBook, bytes32 _marketId) {
		orderBook = _orderBook;
		marketId = _marketId;
	}

	function setAttack(Attack _attack) external {
		attack = _attack;
	}

	function approve(address token) external {
		IERC20(token).approve(address(orderBook), type(uint256).max);
	}

	function placeOrder(MatchingOrderBook.Side side, uint baseQuantity, uint price) external returns (uint128) {
		return orderBook.placeOrder(marketId, side, baseQuantity, price, address(0));
	}

	function cancelOrder(MatchingOrderBook.Side side, uint128 orderId) external {
		orderBook.cancelOrder(marketId, side, orderId);
	}

	function withdrawFailedPayment(address token) external {
		orderBook.withdrawFailedPayment(orderBook.getMarketDetails(marketId).bankAddress, token);
	}

	function onTransferReceived(address, address, uint256, bytes calldata) external returns (bytes4) {
		if (attack == Attack.PLACE_ORDER) {
			orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1e6, 1e6, address(0));
		} else if (attack == Attack.CANCEL_ORDER) {
			orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, 1);
		} else if (attack == Attack.WITHDRAW_FAILED_PAYMENT) {
			orderBook.withdrawFailedPayment(orderBook.getMarketDetails(marketId).bankAddress, msg.sender);
		} else if (attack == Attack.CREATE_MARKET) {
			orderBook.createMarket(address(1), address(2), 0, 0, 0, 1, address(0x0));
		} else if (attack == Attack.BURN_GAS) {
			while (true) {}
		}
		return ITransferReceiver.onTransferReceived.selector;
	}
}
