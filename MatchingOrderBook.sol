// Copyright © 2026 Kedar Iyer
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

pragma solidity ^0.8.20;

import "./libraries/SafeERC20.sol";

using SafeERC20 for IERC20;

contract Bank {
	address immutable owner;

	constructor(address _owner) {
		require (_owner != address(0), "must set owner");
		owner = _owner;
	}

	function withdrawTo(address user, address token, uint amount) external {
		require(msg.sender == owner, "only owner can withdraw funds");
		require(amount > 0, "amount is zero");

		IERC20(token).safeTransfer(user, amount);
	}
}

contract MatchingOrderBook {
	enum Side {
		BUY,
		SELL
	}
	struct Order {
		address user;
		uint baseQuantity;
		uint price;
		uint128 nextOrderId;
		uint128 previousOrderId;
	}
	struct MarketDetails {
		address baseToken;
		address quoteToken;
		uint baseMinPostSize;
		uint quoteMinPostSize;
		uint feeNumerator;
		uint feeDenominator;
		address payable feeReceiver;
		address payable bankAddress;
	}
	struct PlaceOrderVars {
		bool fillOccurred;
		uint quoteQuantity;
		uint usedQuoteQuantity;
		Side makerSide;
		uint128 fillOrderId;
	}
	mapping(bytes32 => MarketDetails) public MARKET_DETAILS; // market_id -> MarketDetails
	mapping(bytes32 => mapping(Side => uint128)) orderbooks; // marketId -> Side -> firstOrderId
	mapping(bytes32 => mapping(Side => mapping(uint128 => Order))) orders; // marketId -> Side -> orderId -> Order
	uint128 public orderCounter = 0; // order counter increments before being saved so the first order ID saved will be 1

	event OrderPlaced(uint indexed orderId, address indexed user, bytes32 indexed markethash, Side side, uint baseQuantity, uint price);
	event OrderCanceled(uint indexed orderId);
	event OrderFill(uint indexed orderId, uint baseQuantity);
	event MarketCreated(bytes32 marketId, address indexed baseToken, address indexed quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, address feeReceiver, address bankAddress);

	function createMarket(address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, address feeReceiver) external {
		bytes32 marketId = getMarketId(baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, feeReceiver);
		require(MARKET_DETAILS[marketId].bankAddress == address(0), "market has already been created");
		address payable bankAddress = payable(address(new Bank(address(this))));
		MARKET_DETAILS[marketId] = MarketDetails(baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, payable(feeReceiver), bankAddress);
		emit MarketCreated(marketId, baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, feeReceiver, bankAddress);
	}

	function placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price) external returns (uint128 orderId) {
		MarketDetails memory marketDetails = MARKET_DETAILS[marketId];
		PlaceOrderVars memory placeOrderVars = PlaceOrderVars(false, 0, 0, Side.BUY, 0);
		require(marketDetails.bankAddress != address(0), "createMarket before placing an order on it");
		require(baseQuantity > 0 && price > 0, "zero quantity/price orders not permitted");

		(bool decimalCallSuccess, uint8 baseTokenDecimals) = IERC20(marketDetails.baseToken).tryGetDecimals();
		require(decimalCallSuccess, "failed to get decimals for token");
		placeOrderVars.quoteQuantity = baseQuantity * price / 10**baseTokenDecimals;
		require(placeOrderVars.quoteQuantity > 0, "calculated quote quantity is zero");

		// This is to transfer tokens into the contract
		// Support is included here for fee-for-transfer tokens which do not send the requested amount exactly.
		// We can remove that support if needed. It is a very annoying feature to support. 
		// Fee-for-transfer tokens can be rejected outright if necessary.
		if (side == Side.SELL) {
			IERC20 baseTokenIERC20 = IERC20(marketDetails.baseToken);
			uint beforeBalance = baseTokenIERC20.balanceOf(marketDetails.bankAddress);
			baseTokenIERC20.safeTransferFrom(msg.sender, marketDetails.bankAddress, baseQuantity);
			uint afterBalance = baseTokenIERC20.balanceOf(marketDetails.bankAddress);
			uint transferredBaseQuantity = afterBalance - beforeBalance;
			if (transferredBaseQuantity != baseQuantity) {
				baseQuantity = transferredBaseQuantity;
				placeOrderVars.quoteQuantity = baseQuantity * price / 10**baseTokenDecimals;
				require(placeOrderVars.quoteQuantity > 0, "calculated quote quantity is zero");
			}
		} else if (side == Side.BUY) {
			IERC20 quoteTokenIERC20 = IERC20(marketDetails.quoteToken);
			uint beforeBalance = quoteTokenIERC20.balanceOf(marketDetails.bankAddress);
			quoteTokenIERC20.safeTransferFrom(msg.sender, marketDetails.bankAddress, placeOrderVars.quoteQuantity);
			uint afterBalance = quoteTokenIERC20.balanceOf(marketDetails.bankAddress);
			uint transferredQuoteQuantity = afterBalance - beforeBalance;
			if (transferredQuoteQuantity != placeOrderVars.quoteQuantity) {
				require(transferredQuoteQuantity > 0, "transferred quote quantity is zero");
				placeOrderVars.quoteQuantity = transferredQuoteQuantity;
				price = baseQuantity * 10**baseTokenDecimals / transferredQuoteQuantity;
			}
		}


		// Block scope this to avoid too many local variables
		// This is the matching engine
		{
			placeOrderVars.makerSide = side == Side.SELL ? Side.BUY : Side.SELL;
			placeOrderVars.fillOrderId = orderbooks[marketId][placeOrderVars.makerSide];
			Order memory fillOrder = orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId];

			// Fill Against Opposite Book
			while (fillOrder.user != address(0)) {
				if (side == Side.SELL) {
					if (price > fillOrder.price) break;
				}
				else { // if (side == Side.BUY) 
					if (price < fillOrder.price) break;
				}

				placeOrderVars.fillOccurred = true;
				uint fillBaseQuantity = (baseQuantity > fillOrder.baseQuantity) ? fillOrder.baseQuantity : baseQuantity;
				uint fillQuoteQuantity = fillBaseQuantity * fillOrder.price / 10**baseTokenDecimals;
				placeOrderVars.usedQuoteQuantity += fillQuoteQuantity;
				emit OrderFill(placeOrderVars.fillOrderId, fillBaseQuantity);

				if (side == Side.SELL) {
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, fillQuoteQuantity);
					Bank(marketDetails.bankAddress).withdrawTo(fillOrder.user, marketDetails.baseToken, fillBaseQuantity);
				} else {
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.baseToken, fillBaseQuantity);
					Bank(marketDetails.bankAddress).withdrawTo(fillOrder.user, marketDetails.quoteToken, fillQuoteQuantity);
				}

				if (baseQuantity >= fillOrder.baseQuantity) {
					delete orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId];
					orderbooks[marketId][placeOrderVars.makerSide] = fillOrder.nextOrderId;
					orders[marketId][placeOrderVars.makerSide][fillOrder.nextOrderId].previousOrderId = 0;
				}
				if (baseQuantity > fillOrder.baseQuantity) {
					baseQuantity -= fillOrder.baseQuantity;
					placeOrderVars.fillOrderId = fillOrder.nextOrderId;
					fillOrder = orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId];
					continue;
				}
				else if (baseQuantity < fillOrder.baseQuantity) {
					orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId].baseQuantity -= baseQuantity;
				}

				if (baseQuantity <= fillOrder.baseQuantity) {
					// refund leftover funds if necessary
					if (side == Side.BUY) {
						uint remainingQuoteQuantity = placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity;
						if (remainingQuoteQuantity > 0) {
							Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, remainingQuoteQuantity);
						}
					}
					return 0;
				}
			}
		}

		// Block scope this to avoid too many local variables
		{
			uint postQuoteQuantity = baseQuantity * price / 10**baseTokenDecimals;
			bool canPost = baseQuantity >= marketDetails.baseMinPostSize && postQuoteQuantity >= marketDetails.quoteMinPostSize;
			require(placeOrderVars.fillOccurred || canPost, "order was too small to post. ran as fill or kill and failed to fill.");

			// refund orders which filled but can't post
			if (placeOrderVars.fillOccurred && !canPost) {
				if (side == Side.SELL) {
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.baseToken, baseQuantity);
				} else {
					// remainingQuoteQuantity and postQuoteQuantity can diverge significantly for orders that fill off the submitted taker price
					uint remainingQuoteQuantity = placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity;
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, remainingQuoteQuantity);
				}
				return 0;
			}
			placeOrderVars.usedQuoteQuantity += postQuoteQuantity;
		}

		// Increment order counter
		orderId = ++orderCounter;

		// Place leftover orders in book then refund leftover funds
		// Block scope this to avoid too many local variables
		{
			uint128 nextOrderId = orderbooks[marketId][side];
			uint128 previousOrderId = 0;
			if (nextOrderId == 0) { //  if the orderbook is empty
				orderbooks[marketId][side] = orderId;
			}
			else {
				bool isSell = (side == Side.SELL);
				while ((isSell && nextOrderId != 0 && price >= orders[marketId][side][nextOrderId].price) || 
				       (!isSell && nextOrderId != 0 && price <= orders[marketId][side][nextOrderId].price)) {
					previousOrderId = nextOrderId;
					nextOrderId = orders[marketId][side][nextOrderId].nextOrderId;
				}
				if (nextOrderId != 0) {
					orders[marketId][side][nextOrderId].previousOrderId = orderId;
				}
				if (previousOrderId == 0) {
					orderbooks[marketId][side] = orderId;
				}
				else {
					orders[marketId][side][previousOrderId].nextOrderId = orderId;
				}
			}
			orders[marketId][side][orderId] = Order(msg.sender, baseQuantity, price, nextOrderId, previousOrderId);

			// refund leftover funds if necessary
			if (side == Side.BUY) {
				uint remainingQuoteQuantity = placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity;
				if (remainingQuoteQuantity > 0) {
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, remainingQuoteQuantity);
				}
			}
		}

		emit OrderPlaced(orderId, msg.sender, marketId, side, baseQuantity, price);
	}

	function cancelOrder(bytes32 marketId, Side side, uint128 orderId) external {
		MarketDetails memory marketDetails = MARKET_DETAILS[marketId];
		Order memory order = orders[marketId][side][orderId];
		require(msg.sender == order.user, "users can only cancel their own order / order may not exist");
		delete orders[marketId][side][orderId];
		if (order.nextOrderId != 0) {
			orders[marketId][side][order.nextOrderId].previousOrderId = order.previousOrderId;
		}
		if (order.previousOrderId != 0) {
			orders[marketId][side][order.previousOrderId].nextOrderId = order.nextOrderId;
		}
		else { // update the orderbook HEAD if the first order gets deleted
			orderbooks[marketId][side] = order.nextOrderId;
		}

		// Re-entrancy here is limited to malicious tokens
		if (side == Side.SELL) {
			Bank(marketDetails.bankAddress).withdrawTo(order.user, marketDetails.baseToken, order.baseQuantity);
		} else if (side == Side.BUY) {
			(bool decimalCallSuccess, uint8 baseTokenDecimals) = IERC20(marketDetails.baseToken).tryGetDecimals();
			require(decimalCallSuccess, "failed to get decimals for token");
			uint quoteQuantity = order.baseQuantity * order.price / 10**baseTokenDecimals;
			Bank(marketDetails.bankAddress).withdrawTo(order.user, marketDetails.quoteToken, quoteQuantity);
		}
		emit OrderCanceled(orderId);
	}

	function getMarketId(address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, address feeReceiver) public pure returns (bytes32) {
		return keccak256(abi.encodePacked(baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, feeReceiver));
	}

	function getMarketDetails(bytes32 marketId) public view returns (MarketDetails memory) {
		return MARKET_DETAILS[marketId];
	}

	function getOrder(bytes32 marketId, Side side, uint128 orderId) external view returns (Order memory) {
		return orders[marketId][side][orderId];
	}

	function getFirstOrderId(bytes32 marketId, Side side) external view returns (uint128) {
		return orderbooks[marketId][side];
	}

	function getOrderBook(bytes32 marketId, Side side, uint depth) external view returns (Order[] memory) {
		Order[] memory returnOrders = new Order[](depth); 
		uint128 orderId = orderbooks[marketId][side];
		for (uint i=0; i < depth; i++) {
			// If the orderbook depth is less than the requested depth, just cut the loop early to save CPU cycles
			if (orders[marketId][side][orderId].baseQuantity == 0) return returnOrders;
			returnOrders[i] = orders[marketId][side][orderId];
			orderId = orders[marketId][side][orderId].nextOrderId;
		}
		return returnOrders;
	}
}
