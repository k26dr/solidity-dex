// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../MatchingOrderBook.sol";
import "../libraries/MockERC20.sol";

// THIS FILE WAS GENERATED ENTIRELY BY CLAUDE OPUS 5.5 FOR TESTING PURPOSES
// Native token version of MatchingOrderBookInvariant.t.sol.
//
// Explanation: A handler with 4 traders randomly places and cancels orders on four native token markets, all
// with a 0.1% fee, and withdraws parked payments:
//   - ETH / USDC: native base. Sells deposit ETH with msg.value. Prices fall between 1900 and 2100 USDC per ETH.
//   - USDC / ETH: native quote. Buys deposit ETH with msg.value. Prices fall between 0.000475 and 0.000525 ETH per USDC.
// Each direction has two markets: one with every minimum at 1, and one with real minimums. The ETH / USDC one has
// post minimums above its order minimums (0.1 ETH / 200 USDC to place an order, 1 ETH / 2000 USDC to rest in the
// book) and the USDC / ETH one has them the other way round (1000 USDC / 0.5 ETH to place, 100 USDC / 0.05 ETH to rest).
// Order sizes are spread evenly across orders of magnitude so plenty land near the minimums. Orders rejected for being
// under an order minimum, or run as immediate-or-cancel because they are under a post minimum, are expected reverts.
// The price bands are narrow so orders cross often. Three traders are plain addresses. The fourth is a contract
// whose receive() writes to storage, which needs more than the 2300 gas stipend. Every native payment the
// matching engine or a cancel sends it fails and is parked, and the handler withdraws it later (withdraws pay
// with unlimited gas). Referrers are picked at random from the traders, so referral fees get parked too.
// Each run makes 3000 calls and fails if any call reverts. Change the runs and depth configs above
// NativeMatchingOrderBookInvariantTest to change that.
//
// After every call it checks:
// 1. All ETH and all USDC are accounted for across the traders, all four banks and the protocol fee receiver.
// 2. Each bank holds exactly the base of its open sells plus parked base, and at least the quote of its open
//    buys plus parked quote.
// 3. Only the contract trader ever has a parked payment. Plain addresses always accept the 2300 gas transfer.
// 4. Both sides of every book are correctly linked and sorted best price first, with no empty orders.
// 5. No book is ever crossed, meaning the best bid is always below the best ask.
// 6. Every order resting in a book meets that market's base and quote post minimums.

// Trader contract whose receive() needs more than the 2300 gas stipend, because writing to storage requires
// more than 2300 gas left. Native payments sent with .transfer always fail; withdraws with unlimited gas succeed.
contract GasHungryWallet {
	uint public received;

	receive() external payable {
		received += msg.value;
	}
}

contract NativeMatchingOrderBookHandler is Test {
	MatchingOrderBook public orderBook;
	MockERC20 public USDC;
	bytes32[2] public nativeBaseMarkets;  // ETH / USDC, 18 decimal base: [minimums of 1, real minimums]
	bytes32[2] public nativeQuoteMarkets; // USDC / ETH, 6 decimal base: [minimums of 1, real minimums]
	address public wallet;
	address[] public actors;

	// ghost totals of everything put into the system
	uint public ethMinted;
	uint public usdcMinted;
	uint public placeCalls;
	uint public cancelCalls;
	uint public withdrawCalls;
	uint public badHintReverts; // hinted orders rejected because the hint was past the insertion point
	uint public minimumReverts; // orders rejected or run as immediate-or-cancel because of the market minimums

	constructor(MatchingOrderBook _orderBook, MockERC20 _USDC, bytes32[2] memory _nativeBaseMarkets, bytes32[2] memory _nativeQuoteMarkets) {
		orderBook = _orderBook;
		USDC = _USDC;
		nativeBaseMarkets = _nativeBaseMarkets;
		nativeQuoteMarkets = _nativeQuoteMarkets;
		wallet = address(new GasHungryWallet());
		actors.push(address(0x1001));
		actors.push(address(0x1002));
		actors.push(address(0x1003));
		actors.push(wallet);
		for (uint i = 0; i < actors.length; i++) {
			vm.prank(actors[i]);
			USDC.approve(address(orderBook), type(uint).max);
		}
	}

	function actorCount() external view returns (uint) {
		return actors.length;
	}

	function _market(bool nativeBase, bool withMinimums) internal view returns (bytes32) {
		uint i = withMinimums ? 1 : 0;
		return nativeBase ? nativeBaseMarkets[i] : nativeQuoteMarkets[i];
	}

	// Everything about one order, kept in memory so the functions below don't run out of stack slots
	struct PendingOrder {
		address actor;
		address referrer;
		bytes32 marketId;
		MatchingOrderBook.Side side;
		uint qty;
		uint price;
		uint value; // ETH sent as msg.value
		uint128 hint;
	}

	// nativeBase and withMinimums pick the market. hintSeed picks no hint, or a random order already on that side as the hint.
	// A random hint can be at the right spot, too early (walks forward) or past the spot (reverts).
	// referrerSeed picks a random actor as the referrer, independent of who places the order (sometimes themselves).
	function placeOrder(uint actorSeed, bool nativeBase, bool withMinimums, bool isSell, uint qty, uint priceSeed, uint hintSeed, uint referrerSeed) external {
		PendingOrder memory o;
		o.actor = actors[actorSeed % actors.length];
		o.referrer = actors[referrerSeed % actors.length];
		o.marketId = _market(nativeBase, withMinimums);
		o.side = isSell ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;
		if (nativeBase) {
			// price is USDC units per 1 ETH. Sizes are spread evenly across orders of magnitude, 1e9 wei to 100 ETH
			uint magnitude = 10 ** bound(qty % 100, 9, 19);
			o.qty = bound(qty / 100, magnitude, magnitude * 10);
			o.price = bound(priceSeed, 1900, 2100) * 1e6;
			if (isSell) o.value = o.qty;
			else _mintUsdc(o.actor, o.qty * o.price / 1e18);
		} else {
			// price is wei per 1 USDC. Sizes are spread evenly across orders of magnitude, 0.001 to 1,000,000 USDC
			uint magnitude = 10 ** bound(qty % 100, 3, 11);
			o.qty = bound(qty / 100, magnitude, magnitude * 10);
			o.price = bound(priceSeed, 475, 525) * 1e12;
			if (isSell) _mintUsdc(o.actor, o.qty);
			else o.value = o.qty * o.price / 1e6;
		}
		if (o.value > 0) {
			vm.deal(o.actor, o.actor.balance + o.value);
			ethMinted += o.value;
		}
		o.hint = hintSeed % 10 == 0 ? 0 : _orderIdAt(o.marketId, o.side, hintSeed);
		_submit(o);
	}

	function _mintUsdc(address actor, uint amount) internal {
		USDC.mint(actor, amount);
		usdcMinted += amount;
	}

	function _submit(PendingOrder memory o) internal {
		// the ETH or USDC stays with the actor if this reverts, so the conservation invariants still hold
		vm.prank(o.actor);
		try orderBook.placeOrderWithHint{value: o.value}(o.marketId, o.side, o.qty, o.price, o.hint, true, false, o.referrer) {
			placeCalls++;
		} catch Error(string memory reason) {
			bytes32 r = keccak256(bytes(reason));
			if (r == keccak256("base quantity is below minimum") ||
				r == keccak256("calculated quote quantity is below minimum") ||
				r == keccak256("order was too small to post. ran as immediate or cancel and failed to fill.")) {
				minimumReverts++;
			} else {
				// otherwise the only allowed revert is a hint past the insertion point
				require(o.hint != 0, reason);
				require(r == keccak256("hint order is too far back in book"), reason);
				badHintReverts++;
			}
		}
	}

	// Returns the (seed % length)-th order id on one side of a book, or 0 if that side is empty
	function _orderIdAt(bytes32 marketId, MatchingOrderBook.Side side, uint seed) internal view returns (uint128 id) {
		uint count;
		id = orderBook.getFirstOrderId(marketId, side);
		while (id != 0) {
			count++;
			id = orderBook.getOrder(marketId, side, id).nextOrderId;
		}
		if (count == 0) return 0;
		uint index = seed % count;
		id = orderBook.getFirstOrderId(marketId, side);
		for (uint i = 0; i < index; i++) {
			id = orderBook.getOrder(marketId, side, id).nextOrderId;
		}
	}

	// Cancels the n-th order on one side of a book, as its owner
	function cancelOrder(bool nativeBase, bool withMinimums, bool isSell, uint indexSeed) external {
		bytes32 marketId = _market(nativeBase, withMinimums);
		MatchingOrderBook.Side side = isSell ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;
		uint128 id = _orderIdAt(marketId, side, indexSeed);
		if (id == 0) return;
		vm.prank(orderBook.getOrder(marketId, side, id).user);
		orderBook.cancelOrder(marketId, side, id);
		cancelCalls++;
	}

	// Withdraws an actor's parked native payment from one market's bank, if it has one
	function withdrawParkedFunds(uint actorSeed, bool nativeBase, bool withMinimums) external {
		address actor = actors[actorSeed % actors.length];
		bytes32 marketId = _market(nativeBase, withMinimums);
		address payable bank = orderBook.getMarketDetails(marketId).bankAddress;
		if (orderBook.parkedPaymentBalance(actor, bank, address(0)) == 0) return;
		vm.prank(actor);
		orderBook.withdrawParkedFunds(bank, address(0));
		withdrawCalls++;
	}
}

/// forge-config: default.invariant.runs = 30
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract NativeMatchingOrderBookInvariantTest is Test {
	MatchingOrderBook orderBook;
	MockERC20 USDC;
	NativeMatchingOrderBookHandler handler;
	bytes32[2] nativeBaseMarkets;  // ETH / USDC: [minimums of 1, real minimums]
	bytes32[2] nativeQuoteMarkets; // USDC / ETH: [minimums of 1, real minimums]
	// Not a precompile, so it accepts native fees within the 2300 gas stipend
	address protocolFeeReceiver = address(0x2008);

	function setUp() public {
		USDC = new MockERC20("USDC", "USDC", 6);
		orderBook = new MatchingOrderBook(payable(protocolFeeReceiver), 50);
		nativeBaseMarkets[0] = orderBook.createMarket(address(0), address(USDC), 1, 1, 1, 1, 1, 1000);
		nativeQuoteMarkets[0] = orderBook.createMarket(address(USDC), address(0), 1, 1, 1, 1, 1, 1000);
		// post minimums above order minimums: 0.1 ETH / 200 USDC to place, 1 ETH / 2000 USDC to rest in the book
		nativeBaseMarkets[1] = orderBook.createMarket(address(0), address(USDC), 1e18, 2000e6, 0.1e18, 200e6, 1, 1000);
		// order minimums above post minimums: 1000 USDC / 0.5 ETH to place, 100 USDC / 0.05 ETH to rest in the book
		nativeQuoteMarkets[1] = orderBook.createMarket(address(USDC), address(0), 100e6, 0.05e18, 1000e6, 0.5e18, 1, 1000);
		handler = new NativeMatchingOrderBookHandler(orderBook, USDC, nativeBaseMarkets, nativeQuoteMarkets);

		targetContract(address(handler));
		bytes4[] memory selectors = new bytes4[](3);
		selectors[0] = NativeMatchingOrderBookHandler.placeOrder.selector;
		selectors[1] = NativeMatchingOrderBookHandler.cancelOrder.selector;
		selectors[2] = NativeMatchingOrderBookHandler.withdrawParkedFunds.selector;
		targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
	}

	function _bank(bytes32 marketId) internal view returns (address) {
		return orderBook.getMarketDetails(marketId).bankAddress;
	}

	function _allBanksBalance(address token) internal view returns (uint total) {
		for (uint i = 0; i < 2; i++) {
			address b = _bank(nativeBaseMarkets[i]);
			address q = _bank(nativeQuoteMarkets[i]);
			total += token == address(0) ? b.balance + q.balance : USDC.balanceOf(b) + USDC.balanceOf(q);
		}
	}

	// No ETH is created or lost: everything dealt is held by a trader, a bank or the protocol fee receiver
	function invariant_nativeConserved() public view {
		uint total;
		for (uint i = 0; i < handler.actorCount(); i++) {
			total += handler.actors(i).balance;
		}
		total += _allBanksBalance(address(0)) + protocolFeeReceiver.balance;
		assertEq(total, handler.ethMinted());
		assertEq(address(orderBook).balance, 0, "order book should never hold ETH");
	}

	// No USDC is created or lost
	function invariant_usdcConserved() public view {
		uint total;
		for (uint i = 0; i < handler.actorCount(); i++) {
			total += USDC.balanceOf(handler.actors(i));
		}
		total += _allBanksBalance(address(USDC)) + USDC.balanceOf(protocolFeeReceiver);
		assertEq(total, handler.usdcMinted());
	}

	// Each bank holds exactly the base of its open sells plus parked base, and at least the quote of its open
	// buys plus parked quote. Quote can be higher because of rounding dust.
	function invariant_banksCoverOpenOrdersAndParkedPayments() public view {
		for (uint i = 0; i < 2; i++) {
			// ETH / USDC
			bytes32 m = nativeBaseMarkets[i];
			address b = _bank(m);
			assertEq(b.balance, _openSellBase(m) + _parked(b, address(0)));
			assertGe(USDC.balanceOf(b), _openBuyQuote(m, 1e18) + _parked(b, address(USDC)));
			// USDC / ETH
			m = nativeQuoteMarkets[i];
			b = _bank(m);
			assertEq(USDC.balanceOf(b), _openSellBase(m) + _parked(b, address(USDC)));
			assertGe(b.balance, _openBuyQuote(m, 1e6) + _parked(b, address(0)));
		}
	}

	// Plain addresses always accept a 2300 gas transfer, so only the contract trader can have parked payments
	function invariant_onlyContractPaymentsParked() public view {
		for (uint i = 0; i < handler.actorCount(); i++) {
			address actor = handler.actors(i);
			if (actor == handler.wallet()) continue;
			_assertNothingParked(actor);
		}
		_assertNothingParked(protocolFeeReceiver);
	}

	function _assertNothingParked(address user) internal view {
		for (uint i = 0; i < 2; i++) {
			address b = _bank(nativeBaseMarkets[i]);
			address q = _bank(nativeQuoteMarkets[i]);
			assertEq(orderBook.parkedPaymentBalance(user, b, address(0)), 0);
			assertEq(orderBook.parkedPaymentBalance(user, b, address(USDC)), 0);
			assertEq(orderBook.parkedPaymentBalance(user, q, address(0)), 0);
			assertEq(orderBook.parkedPaymentBalance(user, q, address(USDC)), 0);
		}
	}

	// Each side of each book is a valid doubly linked list sorted best price first, with no empty orders
	function invariant_booksSortedAndLinked() public view {
		for (uint i = 0; i < 2; i++) {
			_checkSide(nativeBaseMarkets[i], MatchingOrderBook.Side.SELL);
			_checkSide(nativeBaseMarkets[i], MatchingOrderBook.Side.BUY);
			_checkSide(nativeQuoteMarkets[i], MatchingOrderBook.Side.SELL);
			_checkSide(nativeQuoteMarkets[i], MatchingOrderBook.Side.BUY);
		}
	}

	// Matching leaves no crossed book: the best bid is always below the best ask
	function invariant_booksNotCrossed() public view {
		for (uint i = 0; i < 2; i++) {
			_checkNotCrossed(nativeBaseMarkets[i]);
			_checkNotCrossed(nativeQuoteMarkets[i]);
		}
	}

	// Orders only rest in a book if they meet its post minimums, and partial fills that leave less are refunded,
	// so every resting order meets both post minimums
	function invariant_restingOrdersMeetPostMinimums() public view {
		for (uint i = 0; i < 2; i++) {
			_checkPostMinimums(nativeBaseMarkets[i], MatchingOrderBook.Side.SELL, 1e18);
			_checkPostMinimums(nativeBaseMarkets[i], MatchingOrderBook.Side.BUY, 1e18);
			_checkPostMinimums(nativeQuoteMarkets[i], MatchingOrderBook.Side.SELL, 1e6);
			_checkPostMinimums(nativeQuoteMarkets[i], MatchingOrderBook.Side.BUY, 1e6);
		}
	}

	function _checkPostMinimums(bytes32 marketId, MatchingOrderBook.Side side, uint baseUnit) internal view {
		MatchingOrderBook.MarketDetails memory d = orderBook.getMarketDetails(marketId);
		uint128 id = orderBook.getFirstOrderId(marketId, side);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, side, id);
			assertGe(o.baseQuantity, d.basePostMin, "resting order under the base post minimum");
			assertGe(o.baseQuantity * o.price / baseUnit, d.quotePostMin, "resting order under the quote post minimum");
			id = o.nextOrderId;
		}
	}

	function _openSellBase(bytes32 marketId) internal view returns (uint total) {
		uint128 id = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, id);
			total += o.baseQuantity;
			id = o.nextOrderId;
		}
	}

	function _openBuyQuote(bytes32 marketId, uint baseUnit) internal view returns (uint total) {
		uint128 id = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, id);
			total += o.baseQuantity * o.price / baseUnit;
			id = o.nextOrderId;
		}
	}

	// Total parked in one bank for one token, across everyone who can be paid: traders and the protocol fee receiver
	function _parked(address bank, address token) internal view returns (uint total) {
		for (uint i = 0; i < handler.actorCount(); i++) {
			total += orderBook.parkedPaymentBalance(handler.actors(i), bank, token);
		}
		total += orderBook.parkedPaymentBalance(protocolFeeReceiver, bank, token);
	}

	function _checkSide(bytes32 marketId, MatchingOrderBook.Side side) internal view {
		uint128 previousId = 0;
		uint previousPrice = 0;
		uint128 id = orderBook.getFirstOrderId(marketId, side);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, side, id);
			assertTrue(o.user != address(0), "order in list has no owner");
			assertGt(o.baseQuantity, 0, "order in list is empty");
			assertEq(o.previousOrderId, previousId, "previous link broken");
			if (previousId != 0) {
				if (side == MatchingOrderBook.Side.SELL) assertGe(o.price, previousPrice, "sells not ascending");
				else assertLe(o.price, previousPrice, "buys not descending");
			}
			previousId = id;
			previousPrice = o.price;
			id = o.nextOrderId;
		}
	}

	function _checkNotCrossed(bytes32 marketId) internal view {
		uint128 bestAsk = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		uint128 bestBid = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY);
		if (bestAsk == 0 || bestBid == 0) return;
		assertLt(
			orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, bestBid).price,
			orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, bestAsk).price
		);
	}
}
