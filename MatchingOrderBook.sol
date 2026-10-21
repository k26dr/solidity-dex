// Copyright © 2026 Kedar Iyer
// 
// This software operates on a freemium royalty scheme. Any person or entity who makes more than $1k USD equivalent via the fee mechanism embedded in this software owes the copyright holder 50% of all fee revenue after $1k as a royalty. This applies to any forks and modified versions of the repository that use this software as well. 
// 
// The copyright holder maintains the right to modify the royalty percentage or minimum at any time and users of this software must comply with the new royalty rules. 
//
// The requirement for fee royalties extends to anyone who simply creates markets via the smart contracts as well as anybody who re-deploys these contracts. 
// 
// This software can be deployed as is to any chain as long as royalties are maintained, but it cannot be modified in a commercial deployment without a license agreement from the copyright holder. 
// 
// The code in this repository cannot be used as training data for any artifical intelligence system. 
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// We are not responsible for any hacks or loss of funds that occur due to the usage of this contract. 


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
		uint baseTokenDecimals;
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
	// Tokens can freeze addresses and that will cause sends to revert 
	// Need to track failed payments so users can get a refund later without bricking the book 
	mapping(address => mapping(address => mapping(address => uint))) failedPayments; // user -> bankAddress -> token -> amount
	uint128 public orderCounter = 0; // order counter increments before being saved so the first order ID saved will be 1
	address payable protocolFeeReceiver;
	uint protocolFeePercent = 50; // Protocol fee as a percent of market fee. MAX 50.
	bool protocolFeeLocked = false; // If protocolFeeReceiver address gets hacked, this variable can be set to lock the protocol fee at 0
	bool reentrancyGuard = false;

	event OrderPlaced(uint indexed orderId, address indexed user, bytes32 indexed markethash, Side side, uint baseQuantity, uint price);
	event OrderCanceled(uint indexed orderId);
	event OrderFill(uint indexed orderId, address indexed maker, address indexed taker, bytes32 marketId, uint baseQuantity, uint price);
	event MarketCreated(bytes32 indexed marketId, address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, uint baseTokenDecimals, address feeReceiver, address bankAddress);
	event PaymentFailed(address indexed user, address indexed bank, address indexed token, uint amount);

	constructor(address payable _protocolFeeReceiver, uint _protocolFeePercent) {
		// initial conditions can be protocolFeeReceiver=address(0) and protocolFeePercent=0 if you want
		// if you do that, the protocol fee will permanently be 0
		if (_protocolFeePercent > 0) {
			require(_protocolFeeReceiver != address(0), "must set protocol fee receiver");
		}
		require(_protocolFeePercent <= 50, "Max protocol fee is 50 percent of market fee");
		protocolFeeReceiver = _protocolFeeReceiver;
		protocolFeePercent = _protocolFeePercent;
	}

	function updateProtocolFee(uint percent) public {
		require(msg.sender == protocolFeeReceiver, "only protocol fee receiver can set new percentage");
		require(percent <= 50, "Max protocol fee is 50 percent of market fee");
		require(!protocolFeeLocked, "Protocol fee control is locked");
		protocolFeePercent = percent;
	}

	function endProtocolFee() public {
		require(msg.sender == protocolFeeReceiver, "only protocol fee receiver can lock protocol fee");
		protocolFeePercent = 0;
		protocolFeeLocked = true;
		protocolFeeReceiver = payable(address(0));
	}

	function createMarket(address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, address feeReceiver) external {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		require(feeNumerator < feeDenominator, "fee numerator must be less than the denominator");
		require(baseToken != quoteToken, "base and quote token must be different");
		bytes32 marketId = getMarketId(baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, feeReceiver);
		require(MARKET_DETAILS[marketId].bankAddress == address(0), "market has already been created");
		address payable bankAddress = payable(address(new Bank(address(this))));
		(bool decimalCallSuccess, uint8 baseTokenDecimals) = IERC20(baseToken).tryGetDecimals();
		require(decimalCallSuccess, "failed to get decimals for token");
		MARKET_DETAILS[marketId] = MarketDetails(baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, baseTokenDecimals, payable(feeReceiver), bankAddress);
		emit MarketCreated(marketId, baseToken, quoteToken, baseMinimum, quoteMinimum, feeNumerator, feeDenominator, baseTokenDecimals, feeReceiver, bankAddress);
		reentrancyGuard = false;
	}

	function placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price) external returns (uint128 orderId) {
		return placeOrderWithHint(marketId, side, baseQuantity, price, 0);
	}

	// placeOrder function with hint
	// to place orders further back in the book, the hintOrderId can be used to specify an order ID to start iterating at
	// if the placement of the hint order is further in the book than the order should be placed, it will fail with an error
	// set hintOrderId = 0 if you don't want to include a hint
	function placeOrderWithHint(bytes32 marketId, Side side, uint baseQuantity, uint price, uint128 hintOrderId) public returns (uint128 orderId) {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		MarketDetails memory marketDetails = MARKET_DETAILS[marketId];
		PlaceOrderVars memory placeOrderVars = PlaceOrderVars(false, 0, 0, Side.BUY, 0);
		require(marketDetails.bankAddress != address(0), "createMarket before placing an order on it");
		require(baseQuantity > 0 && price > 0, "zero quantity/price orders not permitted");

		placeOrderVars.quoteQuantity = baseQuantity * price / 10**marketDetails.baseTokenDecimals;
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
				placeOrderVars.quoteQuantity = baseQuantity * price / 10**marketDetails.baseTokenDecimals;
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
				price = transferredQuoteQuantity * 10**marketDetails.baseTokenDecimals / baseQuantity;
				require(price > 0, "adjusted price is zero");
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
				uint fillQuoteQuantity = fillBaseQuantity * fillOrder.price / 10**marketDetails.baseTokenDecimals;
				placeOrderVars.usedQuoteQuantity += fillQuoteQuantity;
				emit OrderFill(placeOrderVars.fillOrderId, fillOrder.user, msg.sender, marketId, fillBaseQuantity, fillOrder.price);

				if (side == Side.SELL) {
					uint takerFee = fillQuoteQuantity * marketDetails.feeNumerator * (100 - protocolFeePercent) / marketDetails.feeDenominator / 100;
					uint protocolFee = fillQuoteQuantity * marketDetails.feeNumerator * protocolFeePercent / marketDetails.feeDenominator / 100;
					uint quoteQuantityMinusFees = fillQuoteQuantity - takerFee - protocolFee;
					if (quoteQuantityMinusFees > 0) {
						Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, quoteQuantityMinusFees);
					}
					_payOrPark(marketDetails.bankAddress, fillOrder.user, marketDetails.baseToken, fillBaseQuantity);
					_payOrPark(marketDetails.bankAddress, marketDetails.feeReceiver, marketDetails.quoteToken, takerFee);
					_payOrPark(marketDetails.bankAddress, protocolFeeReceiver, marketDetails.quoteToken, protocolFee);
				} else {
					uint takerFee = fillBaseQuantity * marketDetails.feeNumerator * (100 - protocolFeePercent) / marketDetails.feeDenominator / 100;
					uint protocolFee = fillBaseQuantity * marketDetails.feeNumerator * protocolFeePercent / marketDetails.feeDenominator / 100;
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.baseToken, fillBaseQuantity - takerFee - protocolFee);
					_payOrPark(marketDetails.bankAddress, fillOrder.user, marketDetails.quoteToken, fillQuoteQuantity);
					_payOrPark(marketDetails.bankAddress, marketDetails.feeReceiver, marketDetails.baseToken, takerFee);
					_payOrPark(marketDetails.bankAddress, protocolFeeReceiver, marketDetails.baseToken, protocolFee);
				}

				if (baseQuantity >= fillOrder.baseQuantity) {
					delete orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId];
					orderbooks[marketId][placeOrderVars.makerSide] = fillOrder.nextOrderId;
					if (fillOrder.nextOrderId != 0) {
						orders[marketId][placeOrderVars.makerSide][fillOrder.nextOrderId].previousOrderId = 0;
					}
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
					reentrancyGuard = false;
					return 0;
				}
			}
		}

		// Block scope this to avoid too many local variables
		{
			uint postQuoteQuantity = baseQuantity * price / 10**marketDetails.baseTokenDecimals;
			bool canPost = baseQuantity >= marketDetails.baseMinPostSize && postQuoteQuantity >= marketDetails.quoteMinPostSize;
			require(placeOrderVars.fillOccurred || canPost, "order was too small to post. ran as fill or kill and failed to fill.");

			// refund orders which filled but can't post
			if (placeOrderVars.fillOccurred && !canPost) {
				if (side == Side.SELL) {
					Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.baseToken, baseQuantity);
				} else {
					// remainingQuoteQuantity and postQuoteQuantity can diverge significantly for orders that fill off the submitted taker price
					uint remainingQuoteQuantity = placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity;
					if (remainingQuoteQuantity > 0) {
						Bank(marketDetails.bankAddress).withdrawTo(msg.sender, marketDetails.quoteToken, remainingQuoteQuantity);
					}
				}
				reentrancyGuard = false;
				return 0;
			}
			placeOrderVars.usedQuoteQuantity += postQuoteQuantity;
		}

		// Increment order counter
		orderId = ++orderCounter;

		// Place leftover orders in book then refund leftover funds
		// Block scope this to avoid too many local variables
		{
			uint128 nextOrderId;
			uint128 previousOrderId;

			// if a hintOrderId is specified, try and start the insertion at that order ID
			// otherwise start from the beginning of the orderbook
			if (hintOrderId != 0) {
				require(orders[marketId][side][hintOrderId].baseQuantity != 0, "hint order does not exist");
				if (side == Side.SELL) {
					require(orders[marketId][side][hintOrderId].price <= price, "hint order is too far back in book");
				} else {
					require(orders[marketId][side][hintOrderId].price >= price, "hint order is too far back in book");
				}
				nextOrderId = hintOrderId;
				previousOrderId = orders[marketId][side][nextOrderId].previousOrderId;
			} else {
				nextOrderId = orderbooks[marketId][side];
				previousOrderId = 0;
			}
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
		reentrancyGuard = false;
	}

	function cancelOrder(bytes32 marketId, Side side, uint128 orderId) external {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
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

		if (side == Side.SELL) {
			_payOrPark(marketDetails.bankAddress, order.user, marketDetails.baseToken, order.baseQuantity);
		} else if (side == Side.BUY) {
			uint quoteQuantity = order.baseQuantity * order.price / 10**marketDetails.baseTokenDecimals;
			_payOrPark(marketDetails.bankAddress, order.user, marketDetails.quoteToken, quoteQuantity);
		}
		emit OrderCanceled(orderId);
		reentrancyGuard = false;
	}

	function withdrawFailedPayment(address bankAddress, address token) public {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		uint amountToSend = failedPayments[msg.sender][bankAddress][token];
		require(amountToSend > 0, "no failed payment balance for user+bank+token combo");
		failedPayments[msg.sender][bankAddress][token] = 0;
		Bank(bankAddress).withdrawTo(msg.sender, token, amountToSend);
		reentrancyGuard = false;
	}

	function _payOrPark(address bank, address to, address token, uint amount) internal {
		if (amount == 0) return;
		try Bank(bank).withdrawTo{gas: 110e3}(to, token, amount) {}
		catch {
			failedPayments[to][bank][token] += amount;
			emit PaymentFailed(to, bank, token, amount);
		}
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

	function failedPaymentBalance(address user, address bank, address token) external view returns (uint) {
		return failedPayments[user][bank][token];
	}
}
