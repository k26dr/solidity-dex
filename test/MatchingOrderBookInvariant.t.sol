// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../MatchingOrderBook.sol";
import "../libraries/MockERC20.sol";

// Drives random place and cancel calls against one WETH / USDC market with a 0.1% fee.
// Prices come from a narrow band so orders cross often and the matching engine is exercised.
// The tests in this file were generated entirely by Claude and have only been reviewed briefly. 
// It seems useful overall because it does so many invariant checks, but there's a lot of magic
// code happening here and I haven't reviewed entirely how the framework operates 

// Explanation: A handler with 3 traders randomly places and cancels orders on a WETH/USDC market with a 0.1% fee. Prices fall between 1900 and 2100, so orders cross often. Each run makes 3000 calls, and the run fails if any call reverts. You can change the number of calls by changing the invariant runs and depth configs before the MatchingOrderBookInvariantTest contract. Please update the total count above if you do. 

// After every call it checks four things:

// 1. All tokens are accounted for across the traders, the bank and the fee receivers.
// 2. The bank holds exactly the base of open sells and at least the quote of open buys.
// 3. Both sides of the book are correctly linked and sorted best price first, with no empty orders.
// 4. The book is never crossed, meaning the best bid is always below the best ask.

contract MatchingOrderBookHandler is Test {
	MatchingOrderBook public orderBook;
	MockERC20 public WETH;
	MockERC20 public USDC;
	bytes32 public marketId;
	address[] public actors;

	// ghost totals of everything minted into the system
	uint public baseMinted;
	uint public quoteMinted;
	uint public placeCalls;
	uint public cancelCalls;
	uint public badHintReverts; // hinted orders rejected because the hint was past the insertion point

	constructor(MatchingOrderBook _orderBook, MockERC20 _WETH, MockERC20 _USDC, bytes32 _marketId) {
		orderBook = _orderBook;
		WETH = _WETH;
		USDC = _USDC;
		marketId = _marketId;
		actors.push(address(0x1001));
		actors.push(address(0x1002));
		actors.push(address(0x1003));
		for (uint i = 0; i < actors.length; i++) {
			vm.startPrank(actors[i]);
			WETH.approve(address(orderBook), type(uint).max);
			USDC.approve(address(orderBook), type(uint).max);
			vm.stopPrank();
		}
	}

	function actorCount() external view returns (uint) {
		return actors.length;
	}

	// hintSeed picks no hint, or a random order already on that side as the hint.
	// A random hint can be at the right spot, too early (walks forward) or past the spot (reverts).
	// referrerSeed picks a random actor as the referrer, independent of who places the order (sometimes themselves).
	function placeOrder(uint actorSeed, bool isSell, uint qty, uint priceSeed, uint hintSeed, uint referrerSeed) external {
		address actor = actors[actorSeed % actors.length];
		address referrer = actors[referrerSeed % actors.length];
		qty = bound(qty, 1e9, 100e18);
		uint price = bound(priceSeed, 1900, 2100) * 1e6; // USDC per 1 WETH
		if (isSell) {
			WETH.mint(actor, qty);
			baseMinted += qty;
		} else {
			uint quote = qty * price / 1e18;
			USDC.mint(actor, quote);
			quoteMinted += quote;
		}
		MatchingOrderBook.Side side = isSell ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;
		uint128 hint = hintSeed % 10 == 0 ? 0 : _orderIdAt(side, hintSeed);

		// minted tokens stay with the actor if this reverts, so the conservation invariant still holds
		vm.prank(actor);
		try orderBook.placeOrderWithHint(marketId, side, qty, price, referrer, hint) {
			placeCalls++;
		} catch Error(string memory reason) {
			// the only allowed revert is a hint past the insertion point
			require(hint != 0, reason);
			require(keccak256(bytes(reason)) == keccak256("hint order is too far back in book"), reason);
			badHintReverts++;
		}
	}

	// Returns the (seed % length)-th order id on one side of the book, or 0 if that side is empty
	function _orderIdAt(MatchingOrderBook.Side side, uint seed) internal view returns (uint128 id) {
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

	// Cancels the n-th order on one side of the book, as its owner
	function cancelOrder(bool isSell, uint indexSeed) external {
		MatchingOrderBook.Side side = isSell ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;
		uint128 id = _orderIdAt(side, indexSeed);
		if (id == 0) return;
		vm.prank(orderBook.getOrder(marketId, side, id).user);
		orderBook.cancelOrder(marketId, side, id);
		cancelCalls++;
	}
}

/// forge-config: default.invariant.runs = 30
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract MatchingOrderBookInvariantTest is Test {
	MatchingOrderBook orderBook;
	MockERC20 WETH;
	MockERC20 USDC;
	MatchingOrderBookHandler handler;
	bytes32 marketId;
	address bank;
	address referrer = address(0x7);
	address protocolFeeReceiver = address(0x8);

	function setUp() public {
		WETH = new MockERC20("WETH", "WETH", 18);
		USDC = new MockERC20("USDC", "USDC", 6);
		orderBook = new MatchingOrderBook(payable(protocolFeeReceiver), 50);
		orderBook.createMarket(address(WETH), address(USDC), 0, 0, 1, 1000);
		marketId = orderBook.getMarketId(address(WETH), address(USDC), 0, 0, 1, 1000);
		bank = orderBook.getMarketDetails(marketId).bankAddress;
		handler = new MatchingOrderBookHandler(orderBook, WETH, USDC, marketId);

		targetContract(address(handler));
		bytes4[] memory selectors = new bytes4[](2);
		selectors[0] = MatchingOrderBookHandler.placeOrder.selector;
		selectors[1] = MatchingOrderBookHandler.cancelOrder.selector;
		targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
	}

	function _sumHolders(MockERC20 token) internal view returns (uint total) {
		for (uint i = 0; i < handler.actorCount(); i++) {
			total += token.balanceOf(handler.actors(i));
		}
		total += token.balanceOf(bank) + token.balanceOf(referrer) + token.balanceOf(protocolFeeReceiver);
	}

	// No tokens are created or lost: everything minted is held by a trader, the bank or a fee receiver
	function invariant_tokensConserved() public view {
		assertEq(_sumHolders(WETH), handler.baseMinted());
		assertEq(_sumHolders(USDC), handler.quoteMinted());
	}

	// Bank holds exactly the base of all open sells and at least the quote of all open buys
	function invariant_bankCoversOpenOrders() public view {
		uint sellBase;
		uint128 id = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, id);
			sellBase += o.baseQuantity;
			id = o.nextOrderId;
		}
		uint buyQuote;
		id = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY);
		while (id != 0) {
			MatchingOrderBook.Order memory o = orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, id);
			buyQuote += o.baseQuantity * o.price / 1e18;
			id = o.nextOrderId;
		}
		assertEq(WETH.balanceOf(bank), sellBase);
		assertGe(USDC.balanceOf(bank), buyQuote);
	}

	// Each side is a valid doubly linked list sorted best price first, with no empty orders
	function invariant_bookSortedAndLinked() public view {
		_checkSide(MatchingOrderBook.Side.SELL);
		_checkSide(MatchingOrderBook.Side.BUY);
	}

	function _checkSide(MatchingOrderBook.Side side) internal view {
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

	// Matching leaves no crossed book: the best bid is always below the best ask
	function invariant_bookNotCrossed() public view {
		uint128 bestAsk = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		uint128 bestBid = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY);
		if (bestAsk == 0 || bestBid == 0) return;
		assertLt(
			orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, bestBid).price,
			orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, bestAsk).price
		);
	}
}
