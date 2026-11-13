// Copyright © 2026 Kedar Iyer
// 
// This code cannot be deployed, extended, forked, transpiled, scraped, used as training data, or modified in any way without the permission of the owner. 
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

	function withdrawTo(address user, address token, uint amount, bool allowUnlimitedGasForNativeToken) external {
		require(msg.sender == owner, "only owner can withdraw funds");
		require(amount > 0, "amount is zero");
		if (token == address(0)) {
			if (allowUnlimitedGasForNativeToken) {
				(bool sent,) = user.call{value: amount}("");
				require(sent, "native token send to user failed");
			}
			else {
				(bool sent,) = user.call{value: amount, gas: 10e3}("");
				require(sent, "native token send to user failed");
			}
		}
		else {
			IERC20(token).safeTransfer(user, amount);
		}
	}

	// Contract can receive native token
	receive() external payable {}
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
		uint basePostMin;
		uint quotePostMin;
		uint baseOrderMin;
		uint quoteOrderMin;
		uint feeNumerator;
		uint feeDenominator;
		uint baseTokenDecimals;
		address payable bankAddress;
	}
	struct PlaceOrderVars {
		bool fillOccurred;
		uint quoteQuantity;
		uint usedQuoteQuantity;
		Side makerSide;
		uint128 fillOrderId;
		uint remainingMakerBaseQuantity;
		uint remainingMakerQuoteQuantity;
		uint makerOrderPrice;
		address maker;
		uint fillBaseQuantity;
		uint fillQuoteQuantity;
		uint takerOwed;
		uint takerFeeOwed;
		uint protocolFeeOwed;
	}
	mapping(bytes32 => MarketDetails) public MARKET_DETAILS; // market_id -> MarketDetails
	mapping(bytes32 => mapping(Side => uint128)) orderbooks; // marketId -> Side -> firstOrderId
	mapping(bytes32 => mapping(Side => mapping(uint128 => Order))) orders; // marketId -> Side -> orderId -> Order
	// Tokens can freeze addresses and that will cause sends to revert 
	// Need to track failed payments so users can get a refund later without bricking the book 
	mapping(address => mapping(address => mapping(address => uint))) failedPayments; // user -> bankAddress -> token -> amount
	uint128 public orderCounter = 0; // order counter increments before being saved so the first order ID saved will be 1
	address payable public protocolFeeReceiver;
	uint public protocolFeePercent = 50; // Protocol fee as a percent of market fee. MAX 50.
	bool public protocolFeeLocked = false; // If protocolFeeReceiver address gets hacked, this variable can be set to lock the protocol fee at 0
	bool reentrancyGuard = false;

	event OrderPlaced(uint indexed orderId, address indexed user, bytes32 indexed markethash, Side side, uint baseQuantity, uint price);
	event OrderCanceled(uint indexed orderId, address sentTo);
	event OrderFill(uint indexed orderId, address indexed maker, address indexed taker, bytes32 marketId, uint baseQuantity, uint price, address referrer);
	event OrderRefunded(uint indexed orderId, address token, uint quantity);
	event MarketCreated(bytes32 indexed marketId, address baseToken, address quoteToken, uint basePostMin, uint quotePostMin, uint baseOrderMin, uint quoteOrderMin, uint feeNumerator, uint feeDenominator, uint baseTokenDecimals, address bankAddress);
	event PaymentFailed(address indexed user, address indexed bank, address indexed token, uint amount);
	event WithdrawFailedPayment(address indexed user, address indexed bank, address indexed token, uint amount, address sentTo);
	event ProtocolFeeChanged(uint newPercent);

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
		emit ProtocolFeeChanged(percent);
	}

	function endProtocolFee() public {
		require(msg.sender == protocolFeeReceiver, "only protocol fee receiver can lock protocol fee");
		protocolFeePercent = 0;
		protocolFeeLocked = true;
		protocolFeeReceiver = payable(address(0));
		emit ProtocolFeeChanged(0);
	}

	function createMarket(address baseToken, address quoteToken, uint basePostMin, uint quotePostMin, uint baseOrderMin, uint quoteOrderMin, uint feeNumerator, uint feeDenominator) external returns (bytes32 marketId) {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		require(basePostMin > 0, "basePostMin must be atleast 1");
		require(quotePostMin > 0, "quotePostMin must be atleast 1");
		require(baseOrderMin > 0, "baseOrderMin must be atleast 1");
		require(quoteOrderMin > 0, "quoteOrderMin must be atleast 1");
		require(feeNumerator < feeDenominator, "fee numerator must be less than the denominator");
		require(baseToken != quoteToken, "base and quote token must be different");
		marketId = getMarketId(baseToken, quoteToken, basePostMin, quotePostMin, baseOrderMin, quoteOrderMin, feeNumerator, feeDenominator);
		require(MARKET_DETAILS[marketId].bankAddress == address(0), "market has already been created");
		address payable bankAddress = payable(address(new Bank(address(this))));
		uint8 baseTokenDecimals;
		if (baseToken == address(0)) {
			// This is a little brittle. I'm not sure I can guarantee native tokens have 18 decimals. 
			// But I'm not sure it's possible to check in solidity either.
			baseTokenDecimals = 18;
		}
		else {
			(bool decimalCallSuccess, uint8 baseTokenDecimalsVal) = IERC20(baseToken).tryGetDecimals();
			require(decimalCallSuccess, "failed to get decimals for token");
			baseTokenDecimals = baseTokenDecimalsVal;
		}
		MARKET_DETAILS[marketId] = MarketDetails(baseToken, quoteToken, basePostMin, quotePostMin, baseOrderMin, quoteOrderMin, feeNumerator, feeDenominator, baseTokenDecimals, bankAddress);
		emit MarketCreated(marketId, baseToken, quoteToken, basePostMin, quotePostMin, baseOrderMin, quoteOrderMin, feeNumerator, feeDenominator, baseTokenDecimals, bankAddress);
		reentrancyGuard = false;
	}

	// For markets with no fee you can place orders without a referrer
	function placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price) external payable returns (uint128 orderId) {
		return placeOrderWithHint(marketId, side, baseQuantity, price, 0, true, address(0));
	}

	// referrer gets (100 - protocolFeePercent)% of any taker fee for the market
	function placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price, address referrer) external payable returns (uint128 orderId) {
		return placeOrderWithHint(marketId, side, baseQuantity, price, 0, true, referrer);
	}

	// if you want to place an order with a hint and no referrer
	function placeOrderWithHint(bytes32 marketId, Side side, uint baseQuantity, uint price, uint128 hintOrderId, bool revertOnBadHint) public payable returns (uint128 orderId) {
		return placeOrderWithHint(marketId, side, baseQuantity, price, hintOrderId, revertOnBadHint, address(0));
	}

	// placeOrder function with hint
	// to place orders further back in the book, the hintOrderId can be used to specify an order ID to start iterating at
	// if the placement of the hint order is further in the book than the order should be placed, 
	// it will either fail with an error if revertOnBadHint is set to true or run as a normal insert if revertOnBadHint is set false
	// set hintOrderId = 0 if you don't want to include a hint
	// The recommended behavior for revertOnBadHint is true to save gas
	// If you want to place hints on orders close to the front of a book (not that you necessarily should, front of the book orders can be run without a hint)
	// you can set this to false as a convenience so that if the hint order gets filled, your order runs as a normal insert
	// referrer gets (100 - protocolFeePercent)% of any taker fee for the market
	function placeOrderWithHint(bytes32 marketId, Side side, uint baseQuantity, uint price, uint128 hintOrderId, bool revertOnBadHint, address referrer) public payable returns (uint128 orderId) {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		MarketDetails memory marketDetails = MARKET_DETAILS[marketId];
		PlaceOrderVars memory placeOrderVars = PlaceOrderVars(false, 0, 0, Side.BUY, 0, 0, 0, 0, address(0), 0, 0, 0, 0, 0);
		require(marketDetails.bankAddress != address(0), "createMarket before placing an order on it");
		require(baseQuantity >= marketDetails.baseOrderMin, "base quantity is below minimum");
		require(price > 0, "zero price orders not permitted");
		require(referrer != address(this), "cannot use orderbook contract as referrer");

		placeOrderVars.quoteQuantity = baseQuantity * price / 10**marketDetails.baseTokenDecimals;
		require(placeOrderVars.quoteQuantity >= marketDetails.quoteOrderMin, "calculated quote quantity is below minimum");

		// This is to transfer tokens into the contract
		// Support is included here for fee-for-transfer tokens which do not send the requested amount exactly.
		// We can remove that support if needed. It is a very annoying feature to support. 
		// Fee-for-transfer tokens can be rejected outright if necessary.
		if (side == Side.SELL) {
			// For markets with the native token, the token is deposited. send it to the bank.
			if (marketDetails.baseToken == address(0)) {
				require(msg.value == baseQuantity, "improper amount of native token sent");
				marketDetails.bankAddress.transfer(msg.value);
			}
			else {
				require(msg.value == 0, "native token improperly sent");
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
			}
		} else if (side == Side.BUY) {
			// For markets with the native token, the token is deposited. send it to the bank.
			if (marketDetails.quoteToken == address(0)) {
				require(msg.value == placeOrderVars.quoteQuantity, "improper amount of native token sent");
				marketDetails.bankAddress.transfer(msg.value);
			}
			else {
				require(msg.value == 0, "native token improperly sent");
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
				placeOrderVars.fillBaseQuantity = (baseQuantity > fillOrder.baseQuantity) ? fillOrder.baseQuantity : baseQuantity;
				placeOrderVars.fillQuoteQuantity = placeOrderVars.fillBaseQuantity * fillOrder.price / 10**marketDetails.baseTokenDecimals;
				placeOrderVars.usedQuoteQuantity += placeOrderVars.fillQuoteQuantity;
				emit OrderFill(placeOrderVars.fillOrderId, fillOrder.user, msg.sender, marketId, placeOrderVars.fillBaseQuantity, fillOrder.price, referrer);

				if (side == Side.SELL) {
					uint takerFee = placeOrderVars.fillQuoteQuantity * marketDetails.feeNumerator * (100 - protocolFeePercent) / marketDetails.feeDenominator / 100;
					uint protocolFee = placeOrderVars.fillQuoteQuantity * marketDetails.feeNumerator * protocolFeePercent / marketDetails.feeDenominator / 100;
					placeOrderVars.takerFeeOwed += takerFee;
					placeOrderVars.protocolFeeOwed += protocolFee;
					placeOrderVars.takerOwed += placeOrderVars.fillQuoteQuantity - takerFee - protocolFee;
					_payOrPark(marketDetails.bankAddress, fillOrder.user, marketDetails.baseToken, placeOrderVars.fillBaseQuantity);
				} else {
					uint takerFee = placeOrderVars.fillBaseQuantity * marketDetails.feeNumerator * (100 - protocolFeePercent) / marketDetails.feeDenominator / 100;
					uint protocolFee = placeOrderVars.fillBaseQuantity * marketDetails.feeNumerator * protocolFeePercent / marketDetails.feeDenominator / 100;
					placeOrderVars.takerFeeOwed += takerFee;
					placeOrderVars.protocolFeeOwed += protocolFee;
					placeOrderVars.takerOwed += placeOrderVars.fillBaseQuantity - takerFee - protocolFee;
					_payOrPark(marketDetails.bankAddress, fillOrder.user, marketDetails.quoteToken, placeOrderVars.fillQuoteQuantity);
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
					
					// if the partially filled orders go below the post minimum, refund the maker with the unfilled quantity
					placeOrderVars.remainingMakerBaseQuantity = orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId].baseQuantity;
					placeOrderVars.makerOrderPrice = orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId].price;
					placeOrderVars.remainingMakerQuoteQuantity = placeOrderVars.remainingMakerBaseQuantity * placeOrderVars.makerOrderPrice / 
						10**marketDetails.baseTokenDecimals;
					if (placeOrderVars.remainingMakerBaseQuantity < marketDetails.basePostMin || 
					    placeOrderVars.remainingMakerQuoteQuantity < marketDetails.quotePostMin) {
						placeOrderVars.maker = orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId].user;
						
						// delete the order
						delete orders[marketId][placeOrderVars.makerSide][placeOrderVars.fillOrderId];
						orderbooks[marketId][placeOrderVars.makerSide] = fillOrder.nextOrderId;
						if (fillOrder.nextOrderId != 0) {
							orders[marketId][placeOrderVars.makerSide][fillOrder.nextOrderId].previousOrderId = 0;
						}

						// refund the remaining amount
						if (placeOrderVars.makerSide == Side.SELL) {
							_payOrPark(marketDetails.bankAddress, placeOrderVars.maker, 
								   marketDetails.baseToken, placeOrderVars.remainingMakerBaseQuantity);
							emit OrderRefunded(placeOrderVars.fillOrderId, marketDetails.baseToken, placeOrderVars.remainingMakerBaseQuantity);
						}
						else {
							_payOrPark(marketDetails.bankAddress, placeOrderVars.maker, 
								   marketDetails.quoteToken, placeOrderVars.remainingMakerQuoteQuantity);
							emit OrderRefunded(placeOrderVars.fillOrderId, marketDetails.quoteToken, placeOrderVars.remainingMakerQuoteQuantity);
						}
					}
				}

				if (baseQuantity <= fillOrder.baseQuantity) {
					uint refundQty = (side == Side.BUY) ? placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity : 0; 
					_settleTakerPlusFees(
						side, 
						refundQty,
						marketDetails.bankAddress,
						marketDetails.baseToken,
						marketDetails.quoteToken,
						placeOrderVars.takerOwed,
						placeOrderVars.takerFeeOwed,
						placeOrderVars.protocolFeeOwed,
						referrer
					);
					reentrancyGuard = false;
					return 0;
				}
			}
		}

		// Block scope this to avoid too many local variables
		{
			uint postQuoteQuantity = baseQuantity * price / 10**marketDetails.baseTokenDecimals;
			bool canPost = baseQuantity >= marketDetails.basePostMin && postQuoteQuantity >= marketDetails.quotePostMin;
			require(placeOrderVars.fillOccurred || canPost, "order was too small to post. ran as immediate or cancel and failed to fill.");

			// refund orders which filled but can't post
			if (placeOrderVars.fillOccurred && !canPost) {
				uint refundQty = (side == Side.BUY) ? placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity : baseQuantity;
				_settleTakerPlusFees(
					side, 
					refundQty,
					marketDetails.bankAddress,
					marketDetails.baseToken,
					marketDetails.quoteToken,
					placeOrderVars.takerOwed,
					placeOrderVars.takerFeeOwed,
					placeOrderVars.protocolFeeOwed,
					referrer
				);
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
			// if the hint order is missing, use the revertOnBadHint argument to decide
			// whether to revert or run a normal insertion
			if (hintOrderId != 0) {
				if (orders[marketId][side][hintOrderId].baseQuantity == 0) {
					if (revertOnBadHint) {
						revert("hint order does not exist");
					}
					else {
						hintOrderId = 0; // this will trigger a default insert
					}
				}
				else if (side == Side.SELL && orders[marketId][side][hintOrderId].price > price ||
					(side == Side.BUY && orders[marketId][side][hintOrderId].price < price)) {
					if (revertOnBadHint) {
					       revert("hint order is too far back in book");
					}
					else {
						hintOrderId = 0; // this will trigger a default insert
					}
				}
			} 
			if (hintOrderId != 0) { // hint exists and is usable
				nextOrderId = hintOrderId;
				previousOrderId = orders[marketId][side][nextOrderId].previousOrderId;
			}
			else {
				nextOrderId = orderbooks[marketId][side];
				previousOrderId = 0;
			}

			// Determine where in the book the order goes then insert it there
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
			uint refundQty = (side == Side.BUY) ? placeOrderVars.quoteQuantity - placeOrderVars.usedQuoteQuantity : 0; 
			_settleTakerPlusFees(
				side, 
				refundQty,
				marketDetails.bankAddress,
				marketDetails.baseToken,
				marketDetails.quoteToken,
				placeOrderVars.takerOwed,
				placeOrderVars.takerFeeOwed,
				placeOrderVars.protocolFeeOwed,
				referrer
			);
		}

		emit OrderPlaced(orderId, msg.sender, marketId, side, baseQuantity, price);
		reentrancyGuard = false;
	}

	// default cancelOrder sends canceled funds back to user
	function cancelOrder(bytes32 marketId, Side side, uint128 orderId) public {
		cancelOrder(marketId, side, orderId, msg.sender);
	}

	// the optional sendTo address allows canceled funds to be sent to someone other than the canceling user
	// for 99% of use cases, cancelOrder without a custom sendTo address should be sufficient 
	// using the sendTo version adds risk that an improper address is inserted into the sendTo field
	// The sendTo functionality is included so that the cancel functionality can be censorship-resistant for any user
	// where an issuing authority decides to freeze a user's address for their token
	// Outside of that, there is very little reason to use it
	function cancelOrder(bytes32 marketId, Side side, uint128 orderId, address sendTo) public {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		require(sendTo != address(0), "cannot send canceled funds to empty address");
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
			Bank(marketDetails.bankAddress).withdrawTo(sendTo, marketDetails.baseToken, order.baseQuantity, true);
		} else if (side == Side.BUY) {
			uint quoteQuantity = order.baseQuantity * order.price / 10**marketDetails.baseTokenDecimals;
			if (quoteQuantity > 0) {
				Bank(marketDetails.bankAddress).withdrawTo(sendTo, marketDetails.quoteToken, quoteQuantity, true);
			}
		}
		emit OrderCanceled(orderId, sendTo);
		reentrancyGuard = false;
	}

	// default withdrawFailedPayment withdraws to user address
	function withdrawFailedPayment(address payable bankAddress, address token) public {
		withdrawFailedPayment(bankAddress, token, msg.sender);
	}

	// optional sendTo argument allows sending to different addresses in case main address is frozen
	function withdrawFailedPayment(address payable bankAddress, address token, address sendTo) public {
		require(!reentrancyGuard, "malicious attack");
		reentrancyGuard = true;
		require(sendTo != address(0), "cannot withdraw funds to empty address");
		uint amountToSend = failedPayments[msg.sender][bankAddress][token];
		require(amountToSend > 0, "no failed payment balance for user+bank+token combo");
		failedPayments[msg.sender][bankAddress][token] = 0;
		emit WithdrawFailedPayment(msg.sender, bankAddress, token, amountToSend, sendTo);
		Bank(bankAddress).withdrawTo(sendTo, token, amountToSend, true);
		reentrancyGuard = false;
	}

	function _payOrPark(address payable bank, address to, address token, uint amount) internal {
		if (amount == 0) return;
		try Bank(bank).withdrawTo{gas: 200e3}(to, token, amount, false) {}
		catch {
			failedPayments[to][bank][token] += amount;
			emit PaymentFailed(to, bank, token, amount);
		}
	}

	// remainingQuantity is in baseToken on sells and quoteToken on buys
	function _settleTakerPlusFees(Side side, uint remainingQuantity, address payable bank, address baseToken, address quoteToken, uint takerOwed, uint takerFeeOwed, uint protocolFeeOwed, address referrer) internal {
		// taker, protocol, and referrer split the amount the taker receives
		address refundToken = (side == Side.SELL) ? baseToken : quoteToken;
		address feeToken = (side == Side.SELL) ? quoteToken : baseToken;

		_payOrPark(bank, msg.sender, feeToken, takerOwed);
		if (referrer == address(0)) {
			_payOrPark(bank, protocolFeeReceiver, feeToken, takerFeeOwed + protocolFeeOwed);
		}
		else {
			_payOrPark(bank, referrer, feeToken, takerFeeOwed);
			_payOrPark(bank, protocolFeeReceiver, feeToken, protocolFeeOwed);
		}


		// refund leftover taker funds if necessary
		if (remainingQuantity > 0) {
			_payOrPark(bank, msg.sender, refundToken, remainingQuantity);
		}
	}

	function getMarketId(address baseToken, address quoteToken, uint basePostMin, uint quotePostMin, uint baseOrderMin, uint quoteOrderMin, uint feeNumerator, uint feeDenominator) public pure returns (bytes32) {
		return keccak256(abi.encodePacked(baseToken, quoteToken, basePostMin, quotePostMin, baseOrderMin, quoteOrderMin, feeNumerator, feeDenominator));
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
		return getOrderBookWithStartId(marketId, side, depth, 0);
	}

	// get an orderbook starting at a specific order id
	function getOrderBookWithStartId(bytes32 marketId, Side side, uint depth, uint128 startOrderId) public view returns (Order[] memory) {
		Order[] memory returnOrders = new Order[](depth); 
		uint128 orderId;
		if (startOrderId == 0) {
			orderId = orderbooks[marketId][side];
		} else {
			orderId = startOrderId;
			require(orders[marketId][side][orderId].baseQuantity != 0, "startOrderId does not exist");
		}
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
