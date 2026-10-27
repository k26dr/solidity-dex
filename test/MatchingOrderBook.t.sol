// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../MatchingOrderBook.sol"; 
import "../libraries/MockERC20.sol"; 
import "./FeeOnTransferERC20.sol";
import "./PayableERC20.sol";
import "./FreezableERC20.sol";

contract MatchingOrderBookTest is Test {
	MatchingOrderBook orderBook;
	MockERC20 USDC;
	MockERC20 EURT;
	MockERC20 WETH;
	MockERC20 WBTC;
	MockERC20 AAPL;
	address owner = address(0x1);
	address user1 = address(0x2);
	address user2 = address(0x3);
	address user3 = address(0x4);
	address burnAddress = address(0x6);
	address referrer = address(0x7);
	address protocolFeeReceiver = address(0x8);

	// copies of the order book events so tests can check them with vm.expectEmit
	event OrderRefunded(uint indexed orderId, address token, uint quantity);
	event PaymentFailed(address indexed user, address indexed bank, address indexed token, uint amount);
	event WithdrawFailedPayment(address indexed user, address indexed bank, address indexed token, uint amount);
	event ProtocolFeeChanged(uint newPercent);
	event OrderPlaced(uint indexed orderId, address indexed user, bytes32 indexed markethash, MatchingOrderBook.Side side, uint baseQuantity, uint price);
	event OrderCanceled(uint indexed orderId);
	event OrderFill(uint indexed orderId, address indexed maker, address indexed taker, bytes32 marketId, uint baseQuantity, uint price);
	event MarketCreated(bytes32 indexed marketId, address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator, uint baseTokenDecimals, address bankAddress);

	function setUp() public {
		USDC = new MockERC20("USDC", "USDC", 6);
		EURT = new MockERC20("EURT", "EURT", 6);
		WETH = new MockERC20("WETH", "WETH", 18);
		WBTC = new MockERC20("WBTC", "Wrapped Bitcoin", 8);
		AAPL = new MockERC20("AAPL", "Apple", 0);
		orderBook = new MatchingOrderBook(payable(protocolFeeReceiver), 50);
		USDC.mint(user1, 10000e6);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
	}

	function testPlaceOrderBeforeMarketCreation() public {
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.expectRevert("createMarket before placing an order on it"); 
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 115 * 1e6, 1e6);
	}

	function testCreateMarket() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
	}

	function testCreateMultipleMarketsForSamePair() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 10e6, 0, 1);
		orderBook.createMarket(address(EURT), address(USDC), 1, 100e6, 0, 1);
	}
	
	function testHackBankFailWithExternalAddress() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		vm.expectRevert("only owner can withdraw funds");
		Bank(marketDetails.bankAddress).withdrawTo(user1, address(0), 1e18);
	}

	function testCreateMarketTwiceAndFail() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.expectRevert("market has already been created");
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
	}
	
	function testPlaceOneOrderSell() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 115e6, 1e6);
	        MatchingOrderBook.Order memory order = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		assertEq(order.user, user1, "User should match");
		assertEq(order.baseQuantity, 115e6, "Base Quantity should match");
		assertEq(order.price, 1e6, "Price should match");
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 115e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 1);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 115e6);
		assertEq(orders[0].price, 1e6);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
	}

	function testPlaceOneOrderBuy() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, 1e6);
	        MatchingOrderBook.Order memory order = orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, orderId);
		assertEq(order.user, user1, "User should match");
		assertEq(order.baseQuantity, 115e6, "Base Quantity should match");
		assertEq(order.price, 1e6, "Price should match");
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankUsdcBalance, 115e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 1);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 115e6);
		assertEq(orders[0].price, 1e6);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
	}

	function testPlaceTwoOrdersToCheckGas() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, 11e5);
	}

	function testPlace500SellOrders() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		for (uint i=1; i < 500; i++) {
			vm.prank(user1);
			orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 115e6, i * 1e6);
		}
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 35);
		assertEq(orders[0].previousOrderId, 0, "there should be no previousOrderId");
		assertEq(orders[0].nextOrderId, 2, "order pointers are wrong");
		assertEq(orders[33].previousOrderId, 33, "order pointers are wrong");
		assertEq(orders[33].nextOrderId, 35, "order pointers are wrong");
	}

	function testPlace100SellOrders() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		for (uint i=1; i < 101; i++) {
			vm.prank(user1);
			orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 115e6, i * 1e6);
		}
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 99);
		assertEq(orders[0].previousOrderId, 0, "there should be no previousOrderId");
		assertEq(orders[0].nextOrderId, 2, "order pointers are wrong");
		assertEq(orders[33].previousOrderId, 33, "order pointers are wrong");
		assertEq(orders[33].nextOrderId, 35, "order pointers are wrong");
		assertEq(orders[55].previousOrderId, 55, "order pointers are wrong");
		assertEq(orders[55].nextOrderId, 57, "order pointers are wrong");
	}

	function testPlace100BuyOrders() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		for (uint i=1; i < 101; i++) {
			vm.prank(user1);
			orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, i * 1e6);
		}
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 100);
		assertEq(orders[0].previousOrderId, 0, "previousOrderId pointer is wrong");
		assertEq(orders[0].nextOrderId, 99, "nextOrderId pointer is wrong");
		assertEq(orders[33].previousOrderId, 68, "previousOrderId pointer is wrong");
		assertEq(orders[33].nextOrderId, 66, "nextOrderId pointer is wrong");
		assertEq(orders[99].previousOrderId, 2, "previousOrderId pointer is wrong");
		assertEq(orders[99].nextOrderId, 0, "nextOrderId pointer is wrong");
	}

	function testFillOneOrder() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000e6);
		USDC.mint(user2, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 1000e6);
		assertEq(user2eurt, 1000e6);
		assertEq(user2usdc, 0);
	}

	function testFill3SellsWithPartialMakerFill() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		USDC.mint(user1, 3300e6);
		EURT.mint(user2, 2500e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 11e5);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 12e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 2500e6, 1e6);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 2500e6);
		assertEq(user1usdc, 0);
		assertEq(user2eurt, 0);
		assertEq(user2usdc, 2800e6);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 0);
		assertEq(bankUsdcBalance, 500e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 2);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 500e6);
		assertEq(orders[0].price, 1e6);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[1].user, address(0));
		assertEq(orders[1].baseQuantity, 0);
	}

	function testFill3SellsWithLeftover() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 3000e6);
		USDC.mint(user2, 4200e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 11e5);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 12e5);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 4);
		assertEq(orders[0].baseQuantity, 1000e6);
		assertEq(orders[0].price, 1e6);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[0].nextOrderId, 2);
		assertEq(orders[1].baseQuantity, 1000e6);
		assertEq(orders[1].price, 11e5);
		assertEq(orders[1].previousOrderId, 1);
		assertEq(orders[1].nextOrderId, 3);
		assertEq(orders[2].baseQuantity, 1000e6);
		assertEq(orders[2].price, 12e5);
		assertEq(orders[2].previousOrderId, 2);
		assertEq(orders[2].nextOrderId, 0);
		assertEq(orders[3].baseQuantity, 0, "order 4 should be empty");
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 3500e6, 12e5);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 3300e6);
		assertEq(user2eurt, 3000e6);
		assertEq(user2usdc, 300e6, "user2 usdc balance is not right");
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 0);
		assertEq(bankUsdcBalance, 600e6, "bank usdc balance is wrong");
		orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 1);
		assertEq(orders[0].user, user2);
		assertEq(orders[0].baseQuantity, 500e6);
		assertEq(orders[0].price, 12e5);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[0].nextOrderId, 0);
	}

	function testFill3SellsWithPartialFill() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);

		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 3000e6);
		USDC.mint(user2, 3000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 11e5);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 12e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2500e6, 12e5);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 2700e6);
		assertEq(user2eurt, 2500e6);
		assertEq(user2usdc, 300e6);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 500e6);
		assertEq(bankUsdcBalance, 0);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 1);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 500e6);
		assertEq(orders[0].price, 12e5);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
	}

	function testLotsOfOrders() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);

		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 3000e10);
		EURT.mint(user2, 3000e10);
		EURT.mint(user3, 3000e10);
		USDC.mint(user1, 3000e10);
		USDC.mint(user2, 3000e10);
		USDC.mint(user3, 3000e10);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 11e5);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 12e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2500e6, 12e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2500e6, 12e5);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2500e6, 11e5);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2500e6, 11e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 2500e6, 12e5);
	}


	function testCancelOrder() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 1000e6);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
	        MatchingOrderBook.Order memory order = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		vm.prank(user1);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
	        order = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		assertEq(order.user, address(0), "User should be deleted");
		assertEq(order.baseQuantity, 0, "Base Quantity should be deleted");
		assertEq(order.price, 0, "Price should be deleted");
		assertEq(order.nextOrderId, 0, "NextOrderId should be deleted");
		assertEq(order.previousOrderId, 0, "PreviousOrderId should be deleted");
	}

	function testDoubleCancelOrderFail() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 1000e6);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
	        MatchingOrderBook.Order memory order = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		vm.prank(user1);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
	        order = orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		vm.prank(user1);
		vm.expectRevert("users can only cancel their own order / order may not exist");
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
	}
	
	function testCancelOrderWrongUserFail() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 1000e6);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user2);
		vm.expectRevert("users can only cancel their own order / order may not exist");
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
	}

	function testCancelMiddleOrderThenFill() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user2);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user2);
			USDC.transfer(burnAddress, user2usdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);

		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 3000e6);
		vm.prank(user2);
		USDC.approve(address(orderBook), 300e18);
		USDC.mint(user2, 2400e6);
		vm.prank(user1);
		uint128 order1Id = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user1);
		uint128 orderIdToCancel = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 11e5);
		vm.prank(user1);
		uint128 order3Id = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 12e5);
		vm.prank(user1);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderIdToCancel);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 2);
		assertEq(orders[1].price, 12e5);
		assertEq(orders[1].previousOrderId, order1Id);
		assertEq(orders[0].nextOrderId, order3Id);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2000e6, 12e5);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 1000e6);
		assertEq(user1usdc, 2200e6, "user1 post-trade usdc balance is wrong");
		assertEq(user2eurt, 2000e6);
		assertEq(user2usdc, 200e6);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 0);
		assertEq(bankUsdcBalance, 0);
		orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 1);
		assertEq(orders[0].user, address(0));
		assertEq(orders[0].baseQuantity, 0);
		assertEq(orders[0].price, 0);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
	}

	function testFillOrKillTooSmallFill() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1000e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1000e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 1000e6);
		vm.prank(user2);
		USDC.approve(address(orderBook), 300e18);
		USDC.mint(user2, 1000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 2);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 1000e6);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[1].baseQuantity, 0);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 500e6, 1e6);
	}

	function testFillThenTooSmallToPost() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1000e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1000e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 1000e6);
		vm.prank(user2);
		USDC.approve(address(orderBook), 300e18);
		USDC.mint(user2, 1100e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 2);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 1000e6);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[1].baseQuantity, 0);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1100e6, 1e6);
		uint user2usdc = USDC.balanceOf(user2);
		assertEq(user2usdc, 100e6, "remainder was not refunded");
	}

	function testInsertBestOffer() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 2000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 9e5);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 2);
		assertEq(orders[0].price, 9e5);
		assertEq(orders[1].price, 1e6);
	}

	function testInsertBestBid() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		EURT.approve(address(orderBook), 300e18);
		EURT.mint(user1, 2000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 11e5);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 2);
		assertEq(orders[0].price, 11e5);
		assertEq(orders[1].price, 1e6);
	}

	function testFillDifferentBaseSizes() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);

		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 4000e6);
		USDC.mint(user2, 4000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6); // passing in a 0-fee referrer here to just to test
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1500e6, 11e5);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1200e6, 12e5);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 3000e6, 12e5);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1eurt, 300e6);
		assertEq(user1usdc, 3250e6);
		assertEq(user2eurt, 3000e6);
		assertEq(user2usdc, 750e6);
		uint bankEurtBalance = EURT.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankEurtBalance, 700e6);
		assertEq(bankUsdcBalance, 0);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.SELL, 1);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 700e6);
		assertEq(orders[0].price, 12e5);
		assertEq(orders[0].nextOrderId, 0);
	}

	function testQuoteHasMoreDecimalsThanBase() public {
		// zero all balances to start
		uint user1weth = WETH.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2weth = WETH.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		if (user1weth != 0) {
			vm.prank(user1);
			WETH.transfer(burnAddress, user1weth);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2weth != 0) {
			vm.prank(user1);
			WETH.transfer(burnAddress, user2weth);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}

		orderBook.createMarket(address(WETH), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		WETH.approve(address(orderBook), 100e18);
		USDC.mint(user1, 3300e6);
		WETH.mint(user2, 25e17);
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 1, 10e6, 0, 1);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e18, 1000e6); // passing in a 0-fee referrer here to just to test
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e18, 1100e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e18, 1200e6);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 25e17, 1000e6);

		// verify post-trade balances
		user1weth = WETH.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2weth = WETH.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		assertEq(user1weth, 25e17);
		assertEq(user1usdc, 0, "user1 usdc balance is wrong");
		assertEq(user2weth, 0, "user2 weth balance is wrong");
		assertEq(user2usdc, 2800e6);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankWethBalance = WETH.balanceOf(marketDetails.bankAddress);
		uint bankUsdcBalance = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(bankWethBalance, 0);
		assertEq(bankUsdcBalance, 500e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 2);
		assertEq(orders[0].user, user1);
		assertEq(orders[0].baseQuantity, 5e17);
		assertEq(orders[0].price, 1000e6);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[1].user, address(0));
		assertEq(orders[1].baseQuantity, 0);
	}

	function testBaseHasMoreDecimalsThanQuote() public {
		// zero all balances to start
		uint user1wbtc = WBTC.balanceOf(user1);
		uint user1weth = WETH.balanceOf(user1);
		uint user2wbtc = WBTC.balanceOf(user2);
		uint user2weth = WETH.balanceOf(user2);
		if (user1wbtc != 0) {
			vm.prank(user1);
			WBTC.transfer(burnAddress, user1wbtc);
		}
		if (user1weth != 0) {
			vm.prank(user1);
			WETH.transfer(burnAddress, user1weth);
		}
		if (user2wbtc != 0) {
			vm.prank(user1);
			WBTC.transfer(burnAddress, user2wbtc);
		}
		if (user2weth != 0) {
			vm.prank(user1);
			WETH.transfer(burnAddress, user2weth);
		}

		orderBook.createMarket(address(WBTC), address(WETH), 1e3, 1, 0, 1);
		vm.prank(user1);
		WBTC.approve(address(orderBook), 25e7);
		vm.prank(user2);
		WETH.approve(address(orderBook), 48e18);
		WBTC.mint(user1, 25e7);
		WETH.mint(user2, 48e18);
		bytes32 marketId = orderBook.getMarketId(address(WBTC), address(WETH), 1e3, 1, 0, 1);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e8, 15e18);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e8, 16e18);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e8, 17e18);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 25e7, 16e18);

		// verify post-trade balances
		user1weth = WETH.balanceOf(user1);
		user1wbtc = WBTC.balanceOf(user1);
		user2weth = WETH.balanceOf(user2);
		user2wbtc = WBTC.balanceOf(user2);
		assertEq(user1weth, 33e18);
		assertEq(user1wbtc, 0, "user1 wbtc balance is wrong");
		assertEq(user2weth, 0, "user2 weth balance is wrong");
		assertEq(user2wbtc, 2e8);
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		uint bankWethBalance = WETH.balanceOf(marketDetails.bankAddress);
		uint bankWbtcBalance = WBTC.balanceOf(marketDetails.bankAddress);
		assertEq(bankWethBalance, 15e18, "bank weth balance is wrong");
		assertEq(bankWbtcBalance, 5e7, "bank wbtc balance is wrong");
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 2);
		assertEq(orders[0].user, user2);
		assertEq(orders[0].baseQuantity, 1e8);
		assertEq(orders[0].price, 15e18);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
		assertEq(orders[1].user, address(0));
		assertEq(orders[1].baseQuantity, 0);
	}

	function testUnsplittableShares() public {
		orderBook.createMarket(address(AAPL), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(AAPL), address(USDC), 1, 1, 0, 1);
		AAPL.mint(user1, 1);
		USDC.mint(user2, 100e6);
		vm.prank(user1);
		AAPL.approve(address(orderBook), 1);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1, 100e6);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1, 100e6);
		MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, MatchingOrderBook.Side.BUY, 1);
		assertEq(orders[0].user, address(0));
		assertEq(orders[0].baseQuantity, 0);
		assertEq(orders[0].price, 0);
		assertEq(orders[0].nextOrderId, 0);
		assertEq(orders[0].previousOrderId, 0);
	}

	function test1000WethUsdcOrders() public {
		orderBook.createMarket(address(WETH), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 1, 1, 0, 1);
		WETH.mint(user1, 1e30);
		USDC.mint(user1, 1e30);
		WETH.mint(user2, 1e30);
		USDC.mint(user2, 1e30);
		vm.prank(user1);
		WETH.approve(address(orderBook), 1e30);
		vm.prank(user1);
		USDC.approve(address(orderBook), 1e30);
		vm.prank(user2);
		WETH.approve(address(orderBook), 1e30);
		vm.prank(user2);
		USDC.approve(address(orderBook), 1e30);
		for (uint i=0; i<1000; i++) {
			address user = vm.randomUint() % 2 == 0 ? user1 : user2;
			MatchingOrderBook.Side side = vm.randomUint() % 2 == 0 ? MatchingOrderBook.Side.BUY : MatchingOrderBook.Side.SELL;
			uint baseQuantity = vm.randomUint() % 1e20;
			uint price = vm.randomUint() % 100e6 + 1000e6;
			vm.prank(user);
			orderBook.placeOrder(marketId, side, baseQuantity, price);
		}
	}

	function deleteFirstOrderUpdateHead() public {
		orderBook.createMarket(address(WETH), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 1, 1, 0, 1);
		WETH.mint(user1, 1e30);
		vm.prank(user1);
		uint128 firstOrderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1, 1001e6);
		vm.prank(user1);
		uint128 secondOrderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1, 1000e6);
		uint128 orderbookHead = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		require(orderbookHead == firstOrderId);
		vm.prank(user1);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, firstOrderId);
		orderbookHead = orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL);
		require(orderbookHead == secondOrderId, "order cancellation did not update head properly");
	}

	function testOneFillWithTakerFee() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000e6);
		USDC.mint(user2, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 1000e6);
		assertEq(user2eurt, 9999e5);
		assertEq(user2usdc, 0);
		assertEq(feeEurt, 5e4);
		assertEq(feeUsdc, 0);
		assertEq(protocolFeeEurt, 5e4);
		assertEq(protocolFeeUsdc, 0);
	}

	function testTakerFeeWithTakerSell() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user2, 1000e6);
		USDC.mint(user1, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		assertEq(user1eurt, 1000e6);
		assertEq(user1usdc, 0);
		assertEq(user2eurt, 0);
		assertEq(user2usdc, 9999e5);
		assertEq(feeEurt, 0);
		assertEq(feeUsdc, 5e4);
		assertEq(protocolFeeEurt, 0);
		assertEq(protocolFeeUsdc, 5e4);
	}

	function testTakerFeeWithPartialFill() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user2, 1000e6);
		USDC.mint(user1, 2000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 2000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);

		// verify post-trade balances
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		uint marketEurt = EURT.balanceOf(marketDetails.bankAddress);
		uint marketUsdc = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(user1eurt, 1000e6);
		assertEq(user1usdc, 0);
		assertEq(user2eurt, 0);
		assertEq(user2usdc, 9999e5);
		assertEq(feeEurt, 0);
		assertEq(feeUsdc, 5e4);
		assertEq(marketEurt, 0);
		assertEq(marketUsdc, 1000e6);
		assertEq(protocolFeeEurt, 0);
		assertEq(protocolFeeUsdc, 5e4);
	}

	function testTakerFeeWithPartialFillTakerBuy() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 2000e6);
		USDC.mint(user2, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 2000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);

		// verify post-trade balances
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		uint marketEurt = EURT.balanceOf(marketDetails.bankAddress);
		uint marketUsdc = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 1000e6);
		assertEq(user2eurt, 9999e5);
		assertEq(user2usdc, 0);
		assertEq(feeEurt, 5e4);
		assertEq(feeUsdc, 0);
		assertEq(marketEurt, 1000e6);
		assertEq(marketUsdc, 0);
		assertEq(protocolFeeEurt, 5e4);
		assertEq(protocolFeeUsdc, 0);
	}

	function testTakerFeeWithMultipleFills() public {
		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 2000e6);
		USDC.mint(user2, 2000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 500e6, 1e6, referrer);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1500e6, 2e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 2e6, referrer);

		// verify post-trade balances
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		uint marketEurt = EURT.balanceOf(marketDetails.bankAddress);
		uint marketUsdc = USDC.balanceOf(marketDetails.bankAddress);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 1500e6);
		assertEq(user2eurt, 9999e5);
		assertEq(user2usdc, 500e6); // refunded
		assertEq(feeEurt, 5e4);
		assertEq(feeUsdc, 0);
		assertEq(marketEurt, 1000e6);
		assertEq(marketUsdc, 0);
		assertEq(protocolFeeEurt, 5e4);
		assertEq(protocolFeeUsdc, 0);
	}

	function testOrderTooSmallForFee() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 1000);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 2000e6);
		USDC.mint(user2, 2000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 1000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1, 2e6, referrer);

		// verify post-trade balances
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		assertEq(feeEurt, 0);
		assertEq(feeUsdc, 0);
		assertEq(protocolFeeEurt, 0);
		assertEq(protocolFeeUsdc, 0);
	}

	function testFeeTooHigh() public {
		vm.expectRevert("fee numerator must be less than the denominator");
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1000, 1000);
		vm.expectRevert("fee numerator must be less than the denominator");
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 2, 1);
	}

	function testCustomProtocolFee() public {
		vm.prank(protocolFeeReceiver);
		orderBook.updateProtocolFee(20);

		// zero all balances to start
		uint user1eurt = EURT.balanceOf(user1);
		uint user1usdc = USDC.balanceOf(user1);
		uint user2eurt = EURT.balanceOf(user2);
		uint user2usdc = USDC.balanceOf(user2);
		uint feeEurt = EURT.balanceOf(referrer);
		uint feeUsdc = USDC.balanceOf(referrer);
		uint protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		uint protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		if (user1eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user1eurt);
		}
		if (user1usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user1usdc);
		}
		if (user2eurt != 0) {
			vm.prank(user1);
			EURT.transfer(burnAddress, user2eurt);
		}
		if (user2usdc != 0) {
			vm.prank(user1);
			USDC.transfer(burnAddress, user2usdc);
		}
		if (feeEurt != 0) {
			vm.prank(referrer);
			EURT.transfer(burnAddress, feeEurt);
		}
		if (feeUsdc != 0) {
			vm.prank(referrer);
			USDC.transfer(burnAddress, feeUsdc);
		}
		if (protocolFeeEurt != 0) {
			vm.prank(protocolFeeReceiver);
			EURT.transfer(burnAddress, protocolFeeEurt);
		}
		if (protocolFeeUsdc != 0) {
			vm.prank(protocolFeeReceiver);
			USDC.transfer(burnAddress, protocolFeeUsdc);
		}

		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000e6);
		USDC.mint(user2, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 1, 10000);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);

		// verify post-trade balances
		user1eurt = EURT.balanceOf(user1);
		user1usdc = USDC.balanceOf(user1);
		user2eurt = EURT.balanceOf(user2);
		user2usdc = USDC.balanceOf(user2);
		feeEurt = EURT.balanceOf(referrer);
		feeUsdc = USDC.balanceOf(referrer);
		protocolFeeEurt = EURT.balanceOf(protocolFeeReceiver);
		protocolFeeUsdc = USDC.balanceOf(protocolFeeReceiver);
		assertEq(user1eurt, 0);
		assertEq(user1usdc, 1000e6);
		assertEq(user2eurt, 9999e5);
		assertEq(user2usdc, 0);
		assertEq(feeEurt, 8e4);
		assertEq(feeUsdc, 0);
		assertEq(protocolFeeEurt, 2e4);
		assertEq(protocolFeeUsdc, 0);
	}

	function testRevertSetProtocolFeeOver50() public {
		vm.expectRevert("Max protocol fee is 50 percent of market fee");
		vm.prank(protocolFeeReceiver);
		orderBook.updateProtocolFee(80);
	}

	function testMaliciousProtocolFeeSet() public {
		vm.expectRevert("only protocol fee receiver can set new percentage");
		vm.prank(user1);
		orderBook.updateProtocolFee(80);
	}

	// Fee-on-transfer token burns 1% of every transfer, including transfers into and out of the bank
	function testFeeOnTransferBaseToken() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 100);
		orderBook.createMarket(address(TAX), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(TAX), address(USDC), 1, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		TAX.mint(user2, 100e6);
		USDC.mint(user3, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		// sell 100 TAX: bank only receives 99, so the order is recorded as 99
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId).baseQuantity, 99e6);
		assertEq(TAX.balanceOf(user2), 0);
		assertEq(TAX.balanceOf(bank), 99e6);
		assertEq(TAX.totalSupply(), 99e6);

		// buy 50: bank sends 50 TAX and the buyer receives 49.5
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 50e6, 1e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId).baseQuantity, 49e6);
		assertEq(TAX.balanceOf(bank), 49e6);
		assertEq(TAX.balanceOf(user3), 49.5e6);
		assertEq(USDC.balanceOf(user2), 50e6);
		assertEq(USDC.balanceOf(user3), 50e6);

		// buy the remaining 49: buyer receives 48.51 and the order is removed
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 49e6, 1e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId).baseQuantity, 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL), 0);
		assertEq(TAX.balanceOf(bank), 0);
		assertEq(TAX.balanceOf(user3), 98.01e6);
		assertEq(TAX.totalSupply(), 98.01e6);
		assertEq(USDC.balanceOf(user2), 99e6);
		assertEq(USDC.balanceOf(user3), 1e6);
		assertEq(USDC.balanceOf(bank), 0);
	}

	function testFeeOnTransferQuoteToken() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 100);
		orderBook.createMarket(address(EURT), address(TAX), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(TAX), 1, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		TAX.mint(user2, 100e6);
		EURT.mint(user3, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);
		vm.prank(user3);
		EURT.approve(address(orderBook), 100e18);

		// buy 100 EURT at 1.00: bank only receives 99 TAX, so the price is lowered to 0.99
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);
		MatchingOrderBook.Order memory order = orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, orderId);
		assertEq(order.baseQuantity, 100e6);
		assertEq(order.price, 0.99e6);
		assertEq(TAX.balanceOf(user2), 0);
		assertEq(TAX.balanceOf(bank), 99e6);

		// sell 40 EURT into the bid: bank sends 39.6 TAX and the seller receives 39.204
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 40e6, 0.99e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, orderId).baseQuantity, 60e6);
		assertEq(TAX.balanceOf(bank), 59.4e6);
		assertEq(TAX.balanceOf(user3), 39.204e6);
		assertEq(EURT.balanceOf(user2), 40e6);

		// sell the remaining 60 EURT: seller receives another 58.806 TAX and the order is removed
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 60e6, 0.99e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, orderId).baseQuantity, 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);
		assertEq(TAX.balanceOf(bank), 0);
		assertEq(TAX.balanceOf(user3), 98.01e6);
		assertEq(TAX.totalSupply(), 98.01e6);
		assertEq(EURT.balanceOf(user2), 100e6);
		assertEq(EURT.balanceOf(user3), 0);
	}

	function testFeeOnTransferCancelOrder() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 100);
		orderBook.createMarket(address(TAX), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(TAX), address(USDC), 1, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		TAX.mint(user2, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);

		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId).baseQuantity, 99e6);

		// cancel refunds the recorded 99, of which the user receives 98.01
		vm.prank(user2);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.SELL, orderId);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, orderId).baseQuantity, 0);
		assertEq(TAX.balanceOf(bank), 0);
		assertEq(TAX.balanceOf(user2), 98.01e6);
	}

	// Payable token calls back into the receiver on every transfer. Market is EURT / PAY so the quote token carries the hook.
	function _setUpPayableMarket() internal returns (PayableERC20 PAY, bytes32 marketId, address bank, ReentrantReceiver attacker) {
		PAY = new PayableERC20("PAY", "Payable Token", 6);
		orderBook.createMarket(address(EURT), address(PAY), 1, 1, 0, 1);
		marketId = orderBook.getMarketId(address(EURT), address(PAY), 1, 1, 0, 1);
		bank = orderBook.getMarketDetails(marketId).bankAddress;
		attacker = new ReentrantReceiver(orderBook, marketId);
		attacker.approve(address(EURT));
		attacker.approve(address(PAY));
	}

	// Taker payouts are sent directly, so a re-entering taker reverts the whole trade
	function testReentryAsTakerReverts() public {
		(PayableERC20 PAY, bytes32 marketId, address bank, ReentrantReceiver attacker) = _setUpPayableMarket();
		PAY.mint(user2, 100e6);
		vm.prank(user2);
		PAY.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 bidId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);
		EURT.mint(address(attacker), 100e6);

		attacker.setAttack(ReentrantReceiver.Attack.PLACE_ORDER);
		vm.expectRevert("malicious attack");
		attacker.placeOrder(MatchingOrderBook.Side.SELL, 100e6, 1e6);

		// nothing moved
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, bidId).baseQuantity, 100e6);
		assertEq(EURT.balanceOf(address(attacker)), 100e6);
		assertEq(PAY.balanceOf(address(attacker)), 0);
		assertEq(PAY.balanceOf(bank), 100e6);

		// the guard is released, so an honest fill still works
		attacker.setAttack(ReentrantReceiver.Attack.NONE);
		attacker.placeOrder(MatchingOrderBook.Side.SELL, 100e6, 1e6);
		assertEq(PAY.balanceOf(address(attacker)), 100e6);
		assertEq(EURT.balanceOf(user2), 100e6);
		assertEq(PAY.balanceOf(bank), 0);
	}

	// Maker payouts go through _payOrPark, so a re-entering maker cannot block the taker and its payment is parked
	function testReentryAsMakerParksPayment() public {
		(PayableERC20 PAY, bytes32 marketId, address bank, ReentrantReceiver attacker) = _setUpPayableMarket();
		EURT.mint(address(attacker), 100e6);
		uint128 askId = attacker.placeOrder(MatchingOrderBook.Side.SELL, 100e6, 1e6);
		attacker.setAttack(ReentrantReceiver.Attack.PLACE_ORDER);

		PAY.mint(user2, 100e6);
		vm.prank(user2);
		PAY.approve(address(orderBook), 100e18);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);

		// taker is paid, maker order is filled, maker's payment stays in the bank
		assertEq(EURT.balanceOf(user2), 100e6);
		assertEq(PAY.balanceOf(user2), 0);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, askId).baseQuantity, 0);
		assertEq(PAY.balanceOf(address(attacker)), 0);
		assertEq(PAY.balanceOf(bank), 100e6);

		// re-entering while withdrawing the parked payment also fails
		attacker.setAttack(ReentrantReceiver.Attack.WITHDRAW_FAILED_PAYMENT);
		vm.expectRevert("malicious attack");
		attacker.withdrawFailedPayment(address(PAY));
		assertEq(PAY.balanceOf(bank), 100e6);

		// an honest withdraw recovers the parked payment
		attacker.setAttack(ReentrantReceiver.Attack.NONE);
		attacker.withdrawFailedPayment(address(PAY));
		assertEq(PAY.balanceOf(address(attacker)), 100e6);
		assertEq(PAY.balanceOf(bank), 0);
	}

	// Cancel refunds go through _payOrPark, so a re-entering canceller gets its refund parked
	function testReentryOnCancelParksRefund() public {
		(PayableERC20 PAY, bytes32 marketId, address bank, ReentrantReceiver attacker) = _setUpPayableMarket();
		PAY.mint(address(attacker), 100e6);
		uint128 bidId = attacker.placeOrder(MatchingOrderBook.Side.BUY, 100e6, 1e6);
		assertEq(PAY.balanceOf(bank), 100e6);

		attacker.setAttack(ReentrantReceiver.Attack.CANCEL_ORDER);
		attacker.cancelOrder(MatchingOrderBook.Side.BUY, bidId);

		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, bidId).baseQuantity, 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);
		assertEq(PAY.balanceOf(address(attacker)), 0);
		assertEq(PAY.balanceOf(bank), 100e6);

		attacker.setAttack(ReentrantReceiver.Attack.NONE);
		attacker.withdrawFailedPayment(address(PAY));
		assertEq(PAY.balanceOf(address(attacker)), 100e6);
		assertEq(PAY.balanceOf(bank), 0);
	}

	// After endProtocolFee the whole 0.1% market fee goes to the market's feeReceiver and nothing to the protocol
	function testEndProtocolFee() public {
		vm.prank(protocolFeeReceiver);
		orderBook.endProtocolFee();

		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 1000);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 1000);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 2000e6);
		USDC.mint(user3, 2000e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		// taker buys 1000 EURT: 0.1% fee of 1 EURT is taken from the base received
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);
		assertEq(EURT.balanceOf(user3), 999e6);
		assertEq(USDC.balanceOf(user2), 1000e6);
		assertEq(EURT.balanceOf(referrer), 1e6);
		assertEq(EURT.balanceOf(protocolFeeReceiver), 0);

		// taker sells 1000 EURT: 0.1% fee of 1 USDC is taken from the quote received
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		assertEq(EURT.balanceOf(user3), 1999e6);
		assertEq(USDC.balanceOf(user2), 1999e6);
		assertEq(USDC.balanceOf(referrer), 1e6);
		assertEq(USDC.balanceOf(protocolFeeReceiver), 0);

		// protocol receives nothing and nothing is left parked in the bank
		assertEq(EURT.balanceOf(protocolFeeReceiver), 0);
		assertEq(USDC.balanceOf(protocolFeeReceiver), 0);
		assertEq(EURT.balanceOf(bank), 0);
		assertEq(USDC.balanceOf(bank), 0);

		// the old protocol fee receiver can no longer turn the fee back on
		vm.expectRevert("only protocol fee receiver can set new percentage");
		vm.prank(protocolFeeReceiver);
		orderBook.updateProtocolFee(50);
	}

	// Market is EURT / FRZ so payments in the quote token can be blocked by freezing the recipient
	function _setUpFreezableMarket() internal returns (FreezableERC20 FRZ, bytes32 marketId, address bank) {
		FRZ = new FreezableERC20("FRZ", "Freezable Token", 6);
		orderBook.createMarket(address(EURT), address(FRZ), 1, 1, 0, 1);
		marketId = orderBook.getMarketId(address(EURT), address(FRZ), 1, 1, 0, 1);
		bank = orderBook.getMarketDetails(marketId).bankAddress;
	}

	// A frozen maker cannot block the taker. Its payment is parked and withdrawn after it is unfrozen.
	function testFrozenMakerPaymentParked() public {
		(FreezableERC20 FRZ, bytes32 marketId, address bank) = _setUpFreezableMarket();
		EURT.mint(user2, 100e6);
		FRZ.mint(user3, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		FRZ.approve(address(orderBook), 100e18);

		vm.prank(user2);
		uint128 askId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, referrer);
		FRZ.freeze(user2);

		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);

		// trade completes for the taker and the maker's 100 FRZ stays in the bank
		assertEq(EURT.balanceOf(user3), 100e6);
		assertEq(FRZ.balanceOf(user3), 0);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, askId).baseQuantity, 0);
		assertEq(FRZ.balanceOf(user2), 0);
		assertEq(FRZ.balanceOf(bank), 100e6);
		assertEq(orderBook.failedPaymentBalance(user2, bank, address(FRZ)), 100e6);

		// withdrawing while still frozen fails and keeps the parked balance
		vm.expectRevert("ERC20: recipient is frozen");
		vm.prank(user2);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
		assertEq(FRZ.balanceOf(bank), 100e6);
		assertEq(orderBook.failedPaymentBalance(user2, bank, address(FRZ)), 100e6);

		// once unfrozen the maker withdraws the full amount, and only once
		FRZ.unfreeze(user2);
		vm.prank(user2);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
		assertEq(FRZ.balanceOf(user2), 100e6);
		assertEq(FRZ.balanceOf(bank), 0);
		assertEq(orderBook.failedPaymentBalance(user2, bank, address(FRZ)), 0);
		vm.expectRevert("no failed payment balance for user+bank+token combo");
		vm.prank(user2);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
	}

	// A frozen user can still cancel. The refund is parked and withdrawn after it is unfrozen.
	function testFrozenCancelRefundParked() public {
		(FreezableERC20 FRZ, bytes32 marketId, address bank) = _setUpFreezableMarket();
		FRZ.mint(user2, 100e6);
		vm.prank(user2);
		FRZ.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 bidId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		FRZ.freeze(user2);

		vm.prank(user2);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.BUY, bidId);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);
		assertEq(FRZ.balanceOf(user2), 0);
		assertEq(FRZ.balanceOf(bank), 100e6);
		assertEq(orderBook.failedPaymentBalance(user2, bank, address(FRZ)), 100e6);

		FRZ.unfreeze(user2);
		vm.prank(user2);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
		assertEq(FRZ.balanceOf(user2), 100e6);
		assertEq(FRZ.balanceOf(bank), 0);
		assertEq(orderBook.failedPaymentBalance(user2, bank, address(FRZ)), 0);
	}

	// A frozen taker is paid directly, so the whole trade reverts and the maker's order is untouched
	function testFrozenTakerReverts() public {
		(FreezableERC20 FRZ, bytes32 marketId, address bank) = _setUpFreezableMarket();
		FRZ.mint(user2, 100e6);
		EURT.mint(user3, 100e6);
		vm.prank(user2);
		FRZ.approve(address(orderBook), 100e18);
		vm.prank(user3);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 bidId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		FRZ.freeze(user3);

		vm.expectRevert("ERC20: recipient is frozen");
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, referrer);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, bidId).baseQuantity, 100e6);
		assertEq(EURT.balanceOf(user3), 100e6);
		assertEq(FRZ.balanceOf(bank), 100e6);
	}


	function testCreateMarketSameBaseAndQuoteFail() public {
		vm.expectRevert("base and quote token must be different");
		orderBook.createMarket(address(USDC), address(USDC), 1, 1, 0, 1);
	}

	// Taker sell fills 100 of 105 and the 5 EURT leftover is below the 10 EURT minimum, so it is refunded instead of posted
	function testTakerSellLeftoverTooSmallRefunded() public {
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 105e6);
		USDC.mint(user3, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 105e6, 1e6);

		assertEq(orderId, 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL), 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);
		assertEq(EURT.balanceOf(user2), 5e6);
		assertEq(USDC.balanceOf(user2), 100e6);
		assertEq(EURT.balanceOf(user3), 100e6);
		assertEq(EURT.balanceOf(bank), 0);
		assertEq(USDC.balanceOf(bank), 0);
	}

	// Order below the minimum with nothing to fill against runs as fill or kill and reverts
	function testFillOrKillNoFillReverts() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		vm.expectRevert("order was too small to post. ran as fill or kill and failed to fill.");
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 5e6, 1e6);
		assertEq(USDC.balanceOf(user1), 10000e6);
	}

	function testZeroQuantityOrPriceReverts() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		vm.expectRevert("zero quantity/price orders not permitted");
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 0, 1e6);
		vm.expectRevert("zero quantity/price orders not permitted");
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e6, 0);
	}

	// Base token is an address with no code, so decimals() returns nothing
	function testTokenWithoutDecimalsReverts() public {
		address noDecimals = address(0x1234);
		vm.expectRevert("failed to get decimals for token");
		orderBook.createMarket(noDecimals, address(USDC), 1, 1, 0, 1);
	}

	// Fee-on-transfer token that burns 100% of a sell leaves a quote quantity of 0
	// Not realistic but needed a test where the fee-on-transfer takes away the full amount
	function testFeeOnTransferSellNothingReceivedReverts() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 10000);
		orderBook.createMarket(address(TAX), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(TAX), address(USDC), 1, 1, 0, 1);
		TAX.mint(user2, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);
		vm.expectRevert("calculated quote quantity is zero");
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
	}

	// Fee-on-transfer quote token that burns 100% of a buy delivers nothing to the bank
	// Not realistic but needed a test where the fee-on-transfer takes away the full amount
	function testFeeOnTransferBuyNothingReceivedReverts() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 10000);
		orderBook.createMarket(address(EURT), address(TAX), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(TAX), 1, 1, 0, 1);
		TAX.mint(user2, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);
		vm.expectRevert("transferred quote quantity is zero");
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);
	}

	// 99.99% fee leaves 100 units of quote for 1e12 base, so the adjusted price rounds to 0
	function testFeeOnTransferBuyAdjustedPriceZeroReverts() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 9999);
		orderBook.createMarket(address(EURT), address(TAX), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(TAX), 1, 1, 0, 1);
		TAX.mint(user2, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);
		vm.expectRevert("adjusted price is zero");
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e12, 1);
	}

	function testEndProtocolFeeWrongUserReverts() public {
		vm.expectRevert("only protocol fee receiver can lock protocol fee");
		vm.prank(user1);
		orderBook.endProtocolFee();
	}

	function testConstructorZeroAddressesRevert() public {
		vm.expectRevert("must set protocol fee receiver");
		new MatchingOrderBook(payable(address(0)), 30);
		vm.expectRevert("must set owner");
		new Bank(address(0));
	}

	function testConstructorZeroAddressandAmount() public {
		new MatchingOrderBook(payable(address(0)), 0);
	}

	function testBankZeroAmountReverts() public {
		Bank bank = new Bank(address(this));
		vm.expectRevert("amount is zero");
		bank.withdrawTo(user1, address(USDC), 0);
	}

	// Taker receives PAY directly and re-enters createMarket from the token callback
	function testReentryCreateMarketReverts() public {
		(PayableERC20 PAY, bytes32 marketId, , ReentrantReceiver attacker) = _setUpPayableMarket();
		PAY.mint(user2, 100e6);
		vm.prank(user2);
		PAY.approve(address(orderBook), 100e18);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		EURT.mint(address(attacker), 100e6);

		attacker.setAttack(ReentrantReceiver.Attack.CREATE_MARKET);
		vm.expectRevert("malicious attack");
		attacker.placeOrder(MatchingOrderBook.Side.SELL, 100e6, 1e6);
	}

	function testConstructorProtocolFeeOver50Reverts() public {
		vm.expectRevert("Max protocol fee is 50 percent of market fee");
		new MatchingOrderBook(payable(protocolFeeReceiver), 51);
	}

	// Book deployed with no protocol fee receiver and 0% protocol fee: the whole 0.1% market fee goes to the feeReceiver
	function testTradeWithNoProtocolFee() public {
		MatchingOrderBook book = new MatchingOrderBook(payable(address(0)), 0);
		book.createMarket(address(EURT), address(USDC), 1, 1, 1, 1000);
		bytes32 marketId = book.getMarketId(address(EURT), address(USDC), 1, 1, 1, 1000);
		address bank = book.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 2000e6);
		USDC.mint(user3, 2000e6);
		vm.prank(user2);
		EURT.approve(address(book), 100e18);
		vm.prank(user3);
		USDC.approve(address(book), 100e18);

		// taker buys 1000 EURT: 1 EURT fee
		vm.prank(user2);
		book.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		vm.prank(user3);
		book.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);
		assertEq(EURT.balanceOf(user3), 999e6);
		assertEq(USDC.balanceOf(user2), 1000e6);
		assertEq(EURT.balanceOf(referrer), 1e6);

		// taker sells 1000 EURT: 1 USDC fee
		vm.prank(user3);
		book.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1000e6, 1e6, referrer);
		vm.prank(user2);
		book.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6, referrer);
		assertEq(EURT.balanceOf(user3), 1999e6);
		assertEq(USDC.balanceOf(user2), 1999e6);
		assertEq(USDC.balanceOf(referrer), 1e6);

		// nothing is held for address(0) and the bank is empty
		assertEq(book.failedPaymentBalance(address(0), bank, address(EURT)), 0);
		assertEq(book.failedPaymentBalance(address(0), bank, address(USDC)), 0);
		assertEq(USDC.balanceOf(address(0)), 0);
		assertEq(EURT.balanceOf(address(0)), 0);
		assertEq(EURT.balanceOf(bank), 0);
		assertEq(USDC.balanceOf(bank), 0);

		// nobody can turn the protocol fee on
		vm.expectRevert("only protocol fee receiver can set new percentage");
		vm.prank(user1);
		book.updateProtocolFee(50);
	}

	// ---------- Fuzz tests ----------
	// Below this line is a bunch of tests generated by Claude
	// I haven't verified them fully but they pass and seem useful so i have left them in
	// If they ever fail or cause an issue, a manual review would be required

	// Sums open sell base and open buy quote by walking the book, then checks the bank holds exactly the sell base
	// and at least the buy quote, with at most maxQuoteDust left over from rounding on partial fills
	function _assertBankCoversBook(bytes32 marketId, MockERC20 base, MockERC20 quote, uint maxQuoteDust) internal view {
		MatchingOrderBook.MarketDetails memory details = orderBook.getMarketDetails(marketId);
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
			buyQuote += o.baseQuantity * o.price / 10**details.baseTokenDecimals;
			id = o.nextOrderId;
		}
		assertEq(base.balanceOf(details.bankAddress), sellBase);
		uint bankQuote = quote.balanceOf(details.bankAddress);
		assertGe(bankQuote, buyQuote);
		assertLe(bankQuote - buyQuote, maxQuoteDust);
	}

	// Mints exactly what an order needs and approves the book. Returns the amount of base and quote minted.
	function _fundOrder(address user, MockERC20 base, bool isSell, uint qty, uint price, uint decimals) internal returns (uint baseMinted, uint quoteMinted) {
		if (isSell) {
			baseMinted = qty;
			base.mint(user, qty);
			vm.prank(user);
			base.approve(address(orderBook), type(uint).max);
		} else {
			quoteMinted = qty * price / 10**decimals;
			USDC.mint(user, quoteMinted);
			vm.prank(user);
			USDC.approve(address(orderBook), type(uint).max);
		}
	}

	struct FuzzFill {
		uint decimals;
		uint makerQty;
		uint makerPrice;
		uint takerQty;
		uint takerPrice;
		uint baseMinted;
		uint quoteMinted;
	}

	// One maker order and one crossing taker order with random decimals, sizes, prices and market fee.
	// Checks no tokens are created or lost, the maker is paid at its own price, and the bank covers the book.
	function testFuzzSingleFill(uint8 decimalsSeed, bool makerSells, uint makerQty, uint makerPrice, uint takerQty, uint priceImprovement, uint feeNumerator) public {
		FuzzFill memory f;
		f.decimals = bound(decimalsSeed, 0, 18);
		f.makerPrice = bound(makerPrice, 1, 1e24);
		f.makerQty = bound(makerQty, (10**f.decimals + f.makerPrice - 1) / f.makerPrice, 1e30);
		if (makerSells) {
			f.takerPrice = f.makerPrice + bound(priceImprovement, 0, f.makerPrice);
		} else {
			f.takerPrice = f.makerPrice - bound(priceImprovement, 0, f.makerPrice - 1);
		}
		f.takerQty = bound(takerQty, (10**f.decimals + f.takerPrice - 1) / f.takerPrice, 1e30);
		feeNumerator = bound(feeNumerator, 0, 100);

		MockERC20 BASE = new MockERC20("BASE", "BASE", uint8(f.decimals));
		orderBook.createMarket(address(BASE), address(USDC), 1, 1, feeNumerator, 1000);
		bytes32 marketId = orderBook.getMarketId(address(BASE), address(USDC), 1, 1, feeNumerator, 1000);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;

		(uint b, uint q) = _fundOrder(user2, BASE, makerSells, f.makerQty, f.makerPrice, f.decimals);
		f.baseMinted += b;
		f.quoteMinted += q;
		vm.prank(user2);
		orderBook.placeOrder(marketId, makerSells ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY, f.makerQty, f.makerPrice, referrer);

		(b, q) = _fundOrder(user3, BASE, !makerSells, f.takerQty, f.takerPrice, f.decimals);
		f.baseMinted += b;
		f.quoteMinted += q;
		vm.prank(user3);
		orderBook.placeOrder(marketId, makerSells ? MatchingOrderBook.Side.BUY : MatchingOrderBook.Side.SELL, f.takerQty, f.takerPrice, referrer);

		// no tokens created or lost
		assertEq(BASE.balanceOf(user2) + BASE.balanceOf(user3) + BASE.balanceOf(bank) + BASE.balanceOf(referrer) + BASE.balanceOf(protocolFeeReceiver), f.baseMinted);
		assertEq(USDC.balanceOf(user2) + USDC.balanceOf(user3) + USDC.balanceOf(bank) + USDC.balanceOf(referrer) + USDC.balanceOf(protocolFeeReceiver), f.quoteMinted);

		// maker is paid in full at its own price, fees come out of the taker side
		uint fill = f.makerQty < f.takerQty ? f.makerQty : f.takerQty;
		if (makerSells) {
			assertEq(USDC.balanceOf(user2), fill * f.makerPrice / 10**f.decimals);
		} else {
			assertEq(BASE.balanceOf(user2), fill);
		}

		_assertBankCoversBook(marketId, BASE, USDC, 1);
	}

	// Posting and then cancelling any order returns exactly what was deposited and leaves the bank empty
	function testFuzzPlaceAndCancelRefund(uint8 decimalsSeed, bool isSell, uint qty, uint price) public {
		uint decimals = bound(decimalsSeed, 0, 18);
		price = bound(price, 1, 1e24);
		qty = bound(qty, (10**decimals + price - 1) / price, 1e30);

		MockERC20 BASE = new MockERC20("BASE", "BASE", uint8(decimals));
		orderBook.createMarket(address(BASE), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(BASE), address(USDC), 1, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		MatchingOrderBook.Side side = isSell ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;

		(uint baseMinted, uint quoteMinted) = _fundOrder(user2, BASE, isSell, qty, price, decimals);
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, side, qty, price);
		vm.prank(user2);
		orderBook.cancelOrder(marketId, side, orderId);

		assertEq(BASE.balanceOf(user2), baseMinted);
		assertEq(USDC.balanceOf(user2), quoteMinted);
		assertEq(BASE.balanceOf(bank), 0);
		assertEq(USDC.balanceOf(bank), 0);
		assertEq(orderBook.getFirstOrderId(marketId, side), 0);
	}

	// ---------- Price-time priority ----------
	// Generated by Claude, so brevity was not a concern here

	function _fundAndPlace(bytes32 marketId, address user, MatchingOrderBook.Side side, uint qty, uint price) internal returns (uint128) {
		if (side == MatchingOrderBook.Side.SELL) {
			EURT.mint(user, qty);
			vm.prank(user);
			EURT.approve(address(orderBook), type(uint).max);
		} else {
			USDC.mint(user, qty * price / 1e6);
			vm.prank(user);
			USDC.approve(address(orderBook), type(uint).max);
		}
		vm.prank(user);
		return orderBook.placeOrder(marketId, side, qty, price, referrer);
	}

	// Sells at the same price fill in the order they were placed, after any better priced sell
	function testSamePriceSellsFillFirstComeFirstServed() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		address A = address(0x2001);
		address B = address(0x2002);
		address C = address(0x2003);
		address D = address(0x2004);
		address taker = address(0x2005);
		MatchingOrderBook.Side SELL = MatchingOrderBook.Side.SELL;

		uint128 idA = _fundAndPlace(marketId, A, SELL, 100e6, 1e6);
		uint128 idB = _fundAndPlace(marketId, B, SELL, 100e6, 1e6);
		uint128 idC = _fundAndPlace(marketId, C, SELL, 100e6, 1e6);
		uint128 idD = _fundAndPlace(marketId, D, SELL, 50e6, 0.99e6);

		// book order is D (better price), then A, B, C in time order
		assertEq(orderBook.getFirstOrderId(marketId, SELL), idD);
		assertEq(orderBook.getOrder(marketId, SELL, idD).nextOrderId, idA);
		assertEq(orderBook.getOrder(marketId, SELL, idA).nextOrderId, idB);
		assertEq(orderBook.getOrder(marketId, SELL, idB).nextOrderId, idC);
		assertEq(orderBook.getOrder(marketId, SELL, idC).nextOrderId, 0);

		// buy 120: fills all 50 of D at 0.99, then 70 of A at 1.00. B and C are untouched.
		_fundAndPlace(marketId, taker, MatchingOrderBook.Side.BUY, 120e6, 1e6);
		assertEq(USDC.balanceOf(D), 49.5e6);
		assertEq(USDC.balanceOf(A), 70e6);
		assertEq(USDC.balanceOf(B), 0);
		assertEq(USDC.balanceOf(C), 0);
		assertEq(EURT.balanceOf(taker), 120e6);
		assertEq(USDC.balanceOf(taker), 0.5e6); // refund for filling D below the taker's price
		assertEq(orderBook.getFirstOrderId(marketId, SELL), idA);
		assertEq(orderBook.getOrder(marketId, SELL, idA).baseQuantity, 30e6);
		assertEq(orderBook.getOrder(marketId, SELL, idB).baseQuantity, 100e6);
		assertEq(orderBook.getOrder(marketId, SELL, idC).baseQuantity, 100e6);

		// a later sell at the same price joins the back of the queue, behind C
		address E = address(0x2006);
		uint128 idE = _fundAndPlace(marketId, E, SELL, 10e6, 1e6);
		assertEq(orderBook.getOrder(marketId, SELL, idC).nextOrderId, idE);

		// buy 50: A's remaining 30 fills before B, which fills 20
		_fundAndPlace(marketId, taker, MatchingOrderBook.Side.BUY, 50e6, 1e6);
		assertEq(USDC.balanceOf(A), 100e6);
		assertEq(USDC.balanceOf(B), 20e6);
		assertEq(USDC.balanceOf(C), 0);
		assertEq(orderBook.getOrder(marketId, SELL, idA).baseQuantity, 0);
		assertEq(orderBook.getFirstOrderId(marketId, SELL), idB);
		assertEq(orderBook.getOrder(marketId, SELL, idB).previousOrderId, 0);
		assertEq(orderBook.getOrder(marketId, SELL, idB).baseQuantity, 80e6);
		assertEq(orderBook.getOrder(marketId, SELL, idC).baseQuantity, 100e6);
		assertEq(orderBook.getOrder(marketId, SELL, idE).baseQuantity, 10e6);
	}

	// Buys at the same price fill in the order they were placed, after any better priced buy
	function testSamePriceBuysFillFirstComeFirstServed() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		address A = address(0x2001);
		address B = address(0x2002);
		address D = address(0x2004);
		address taker = address(0x2005);
		MatchingOrderBook.Side BUY = MatchingOrderBook.Side.BUY;

		uint128 idA = _fundAndPlace(marketId, A, BUY, 100e6, 1e6);
		uint128 idB = _fundAndPlace(marketId, B, BUY, 100e6, 1e6);
		uint128 idD = _fundAndPlace(marketId, D, BUY, 50e6, 1.01e6);
		assertEq(orderBook.getFirstOrderId(marketId, BUY), idD);
		assertEq(orderBook.getOrder(marketId, BUY, idD).nextOrderId, idA);
		assertEq(orderBook.getOrder(marketId, BUY, idA).nextOrderId, idB);

		// sell 120: fills all 50 of D at 1.01, then 70 of A at 1.00. B is untouched.
		_fundAndPlace(marketId, taker, MatchingOrderBook.Side.SELL, 120e6, 1e6);
		assertEq(EURT.balanceOf(D), 50e6);
		assertEq(EURT.balanceOf(A), 70e6);
		assertEq(EURT.balanceOf(B), 0);
		assertEq(USDC.balanceOf(taker), 50.5e6 + 70e6);
		assertEq(orderBook.getFirstOrderId(marketId, BUY), idA);
		assertEq(orderBook.getOrder(marketId, BUY, idA).baseQuantity, 30e6);
		assertEq(orderBook.getOrder(marketId, BUY, idB).baseQuantity, 100e6);
	}

	// A maker whose token callback burns all gas it is given only burns the capped payout gas, not the taker's whole budget
	function testGasBurningMakerCannotDrainTakerGas() public {
		(PayableERC20 PAY, bytes32 marketId, address bank, ReentrantReceiver attacker) = _setUpPayableMarket();
		EURT.mint(address(attacker), 100e6);
		attacker.placeOrder(MatchingOrderBook.Side.SELL, 100e6, 1e6);
		attacker.setAttack(ReentrantReceiver.Attack.BURN_GAS);

		PAY.mint(user2, 100e6);
		vm.prank(user2);
		PAY.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint gasBefore = gasleft();
		orderBook.placeOrder{gas: 10_000_000}(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		uint gasUsed = gasBefore - gasleft();

		// without the cap the burner would eat almost all 10M gas
		assertLt(gasUsed, 1_000_000);
		assertEq(EURT.balanceOf(user2), 100e6);
		// the maker's 100 PAY was either delivered or parked for withdrawal, never lost
		assertEq(PAY.balanceOf(address(attacker)) + orderBook.failedPaymentBalance(address(attacker), bank, address(PAY)), 100e6);
		assertEq(PAY.balanceOf(bank), orderBook.failedPaymentBalance(address(attacker), bank, address(PAY)));
	}

	// 20 sells at prices 1..20, then insert with a hint near the back of the book
	function testPlaceOrderWithHint() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		MatchingOrderBook.Side SELL = MatchingOrderBook.Side.SELL;
		EURT.mint(user2, 1000e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), type(uint).max);

		uint128[] memory ids = new uint128[](21);
		for (uint i = 1; i <= 20; i++) {
			vm.prank(user2);
			ids[i] = orderBook.placeOrder(marketId, SELL, 10e6, i * 1e6);
		}

		// 15.5 with a hint at the 15 order goes between 15 and 16
		vm.prank(user2);
		uint128 a = orderBook.placeOrderWithHint(marketId, SELL, 10e6, 15.5e6, ids[15]);
		assertEq(orderBook.getOrder(marketId, SELL, a).previousOrderId, ids[15]);
		assertEq(orderBook.getOrder(marketId, SELL, a).nextOrderId, ids[16]);
		assertEq(orderBook.getOrder(marketId, SELL, ids[15]).nextOrderId, a);
		assertEq(orderBook.getOrder(marketId, SELL, ids[16]).previousOrderId, a);

		// same price as the hint goes behind it, keeping first come first served
		vm.prank(user2);
		uint128 b = orderBook.placeOrderWithHint(marketId, SELL, 10e6, 10e6, ids[10]);
		assertEq(orderBook.getOrder(marketId, SELL, b).previousOrderId, ids[10]);
		assertEq(orderBook.getOrder(marketId, SELL, b).nextOrderId, ids[11]);

		// a hint earlier in the book walks forward to the right spot
		vm.prank(user2);
		uint128 c = orderBook.placeOrderWithHint(marketId, SELL, 10e6, 18.5e6, ids[3]);
		assertEq(orderBook.getOrder(marketId, SELL, c).previousOrderId, ids[18]);
		assertEq(orderBook.getOrder(marketId, SELL, c).nextOrderId, ids[19]);

		// the back of the book with a hint at the last order
		vm.prank(user2);
		uint128 d = orderBook.placeOrderWithHint(marketId, SELL, 10e6, 25e6, ids[20]);
		assertEq(orderBook.getOrder(marketId, SELL, d).previousOrderId, ids[20]);
		assertEq(orderBook.getOrder(marketId, SELL, d).nextOrderId, 0);

		// a hint that is too far back
		vm.expectRevert("hint order is too far back in book");
		vm.prank(user2);
		orderBook.placeOrderWithHint(marketId, SELL, 10e6, 15e6, ids[20]);

		// a hint that doesn't exist reverts
		vm.expectRevert("hint order does not exist");
		vm.prank(user2);
		orderBook.placeOrderWithHint(marketId, SELL, 10e6, 5e6, 999);
	}

	// 20 buys at prices 1..20 (best bid 20 at the head), then insert with hints deep in the book
	function testPlaceBuyOrderWithHint() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		MatchingOrderBook.Side BUY = MatchingOrderBook.Side.BUY;
		USDC.mint(user3, 10000e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), type(uint).max);

		uint128[] memory ids = new uint128[](21);
		for (uint i = 1; i <= 20; i++) {
			vm.prank(user3);
			ids[i] = orderBook.placeOrder(marketId, BUY, 10e6, i * 1e6);
		}
		assertEq(orderBook.getFirstOrderId(marketId, BUY), ids[20]);

		// 5.5 with a hint at the 6 order goes between 6 and 5
		vm.prank(user3);
		uint128 a = orderBook.placeOrderWithHint(marketId, BUY, 10e6, 5.5e6, ids[6]);
		assertEq(orderBook.getOrder(marketId, BUY, a).previousOrderId, ids[6]);
		assertEq(orderBook.getOrder(marketId, BUY, a).nextOrderId, ids[5]);
		assertEq(orderBook.getOrder(marketId, BUY, ids[6]).nextOrderId, a);
		assertEq(orderBook.getOrder(marketId, BUY, ids[5]).previousOrderId, a);

		// same price as the hint goes behind it, keeping first come first served
		vm.prank(user3);
		uint128 b = orderBook.placeOrderWithHint(marketId, BUY, 10e6, 10e6, ids[10]);
		assertEq(orderBook.getOrder(marketId, BUY, b).previousOrderId, ids[10]);
		assertEq(orderBook.getOrder(marketId, BUY, b).nextOrderId, ids[9]);

		// a hint earlier in the book walks forward to the right spot
		vm.prank(user3);
		uint128 c = orderBook.placeOrderWithHint(marketId, BUY, 10e6, 2.5e6, ids[18]);
		assertEq(orderBook.getOrder(marketId, BUY, c).previousOrderId, ids[3]);
		assertEq(orderBook.getOrder(marketId, BUY, c).nextOrderId, ids[2]);

		// the back of the book with a hint at the last order
		vm.prank(user3);
		uint128 d = orderBook.placeOrderWithHint(marketId, BUY, 10e6, 0.5e6, ids[1]);
		assertEq(orderBook.getOrder(marketId, BUY, d).previousOrderId, ids[1]);
		assertEq(orderBook.getOrder(marketId, BUY, d).nextOrderId, 0);

		// a hint past where the order belongs reverts instead of misplacing it
		vm.expectRevert("hint order is too far back in book");
		vm.prank(user3);
		orderBook.placeOrderWithHint(marketId, BUY, 10e6, 15e6, ids[14]);
		vm.expectRevert("hint order is too far back in book");
		vm.prank(user3);
		orderBook.placeOrderWithHint(marketId, BUY, 10e6, 15e6, ids[5]);

		// a hint that doesn't exist reverts
		vm.expectRevert("hint order does not exist");
		vm.prank(user3);
		orderBook.placeOrderWithHint(marketId, BUY, 10e6, 5e6, 999);
	}

	// Seeds 10 sells at 1..10 and 5 buys at 0.1..0.5, then reads slices of the book from different start orders
	function testGetOrderBookWithStartId() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		MatchingOrderBook.Side SELL = MatchingOrderBook.Side.SELL;
		MatchingOrderBook.Side BUY = MatchingOrderBook.Side.BUY;
		EURT.mint(user2, 1000e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), type(uint).max);
		USDC.mint(user3, 1000e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), type(uint).max);

		uint128[] memory sells = new uint128[](11);
		for (uint i = 1; i <= 10; i++) {
			vm.prank(user2);
			sells[i] = orderBook.placeOrder(marketId, SELL, 10e6, i * 1e6);
		}
		uint128[] memory buys = new uint128[](6);
		for (uint i = 1; i <= 5; i++) {
			vm.prank(user3);
			buys[i] = orderBook.placeOrder(marketId, BUY, 10e6, i * 0.1e6);
		}

		// start id 0 reads from the head, same as getOrderBook
		MatchingOrderBook.Order[] memory page = orderBook.getOrderBookWithStartId(marketId, SELL, 3, 0);
		MatchingOrderBook.Order[] memory head = orderBook.getOrderBook(marketId, SELL, 3);
		for (uint i = 0; i < 3; i++) {
			assertEq(page[i].price, (i + 1) * 1e6);
			assertEq(page[i].price, head[i].price);
			assertEq(page[i].nextOrderId, head[i].nextOrderId);
		}

		// starting mid-book returns that order first and follows the links
		page = orderBook.getOrderBookWithStartId(marketId, SELL, 3, sells[4]);
		assertEq(page.length, 3);
		assertEq(page[0].price, 4e6);
		assertEq(page[1].price, 5e6);
		assertEq(page[2].price, 6e6);
		assertEq(page[0].user, user2);
		assertEq(page[0].previousOrderId, sells[3]);
		assertEq(page[2].nextOrderId, sells[7]);

		// depth past the end of the book leaves the rest of the array empty
		page = orderBook.getOrderBookWithStartId(marketId, SELL, 5, sells[8]);
		assertEq(page.length, 5);
		assertEq(page[0].price, 8e6);
		assertEq(page[2].price, 10e6);
		assertEq(page[2].nextOrderId, 0);
		assertEq(page[3].baseQuantity, 0);
		assertEq(page[4].user, address(0));

		// depth 0 returns an empty array
		assertEq(orderBook.getOrderBookWithStartId(marketId, SELL, 0, sells[1]).length, 0);

		// buy side reads best bid first, so starting at 0.3 walks down to 0.1
		page = orderBook.getOrderBookWithStartId(marketId, BUY, 5, buys[3]);
		assertEq(page[0].price, 0.3e6);
		assertEq(page[1].price, 0.2e6);
		assertEq(page[2].price, 0.1e6);
		assertEq(page[3].baseQuantity, 0);

		// page through the whole sell side 3 orders at a time using the last order's nextOrderId
		uint128 start = 0;
		uint seen;
		do {
			page = orderBook.getOrderBookWithStartId(marketId, SELL, 3, start);
			start = 0;
			for (uint i = 0; i < 3 && page[i].baseQuantity != 0; i++) {
				seen++;
				assertEq(page[i].price, seen * 1e6);
				start = page[i].nextOrderId;
			}
		} while (start != 0);
		assertEq(seen, 10);

		// unknown ids, ids from the other side, and cancelled orders revert
		vm.expectRevert("startOrderId does not exist");
		orderBook.getOrderBookWithStartId(marketId, SELL, 3, 999);
		vm.expectRevert("startOrderId does not exist");
		orderBook.getOrderBookWithStartId(marketId, SELL, 3, buys[1]);
		vm.prank(user2);
		orderBook.cancelOrder(marketId, SELL, sells[5]);
		vm.expectRevert("startOrderId does not exist");
		orderBook.getOrderBookWithStartId(marketId, SELL, 3, sells[5]);
		// and the book skips the cancelled order
		page = orderBook.getOrderBookWithStartId(marketId, SELL, 2, sells[4]);
		assertEq(page[1].price, 6e6);
	}

	// A frozen referrer's fee share is held, and they withdraw it once unfrozen. The trade itself is not blocked.
	function testFrozenReferrerWithdrawsLater() public {
		FreezableERC20 FRZ = new FreezableERC20("FRZ", "Freezable Token", 6);
		orderBook.createMarket(address(EURT), address(FRZ), 1, 1, 1, 100);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(FRZ), 1, 1, 1, 100);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		address frozenReferrer = address(0x9);
		FRZ.mint(user3, 100e6);
		EURT.mint(user2, 100e6);
		vm.prank(user3);
		FRZ.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);

		// maker bids 100 EURT at 1.00 in FRZ
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);
		FRZ.freeze(frozenReferrer);

		// taker sells into it with the frozen referrer. 1% fee on 100 FRZ: 0.5 to referrer, 0.5 to protocol
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, frozenReferrer);
		assertEq(FRZ.balanceOf(user2), 99e6);
		assertEq(EURT.balanceOf(user3), 100e6);
		assertEq(FRZ.balanceOf(protocolFeeReceiver), 0.5e6);
		assertEq(FRZ.balanceOf(frozenReferrer), 0);
		assertEq(orderBook.failedPaymentBalance(frozenReferrer, bank, address(FRZ)), 0.5e6);
		assertEq(FRZ.balanceOf(bank), 0.5e6);

		// still frozen: withdraw fails and the held balance stays
		vm.expectRevert("ERC20: recipient is frozen");
		vm.prank(frozenReferrer);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
		assertEq(orderBook.failedPaymentBalance(frozenReferrer, bank, address(FRZ)), 0.5e6);

		// unfrozen: referrer withdraws the full share
		FRZ.unfreeze(frozenReferrer);
		vm.prank(frozenReferrer);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
		assertEq(FRZ.balanceOf(frozenReferrer), 0.5e6);
		assertEq(orderBook.failedPaymentBalance(frozenReferrer, bank, address(FRZ)), 0);
		assertEq(FRZ.balanceOf(bank), 0);
	}

	// The order book contract can't be named as referrer, through either entry point, and nothing moves
	function testOrderBookCannotBeReferrer() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 100);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 100);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;

		vm.expectRevert("cannot use orderbook contract as referrer");
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, address(orderBook));

		vm.expectRevert("cannot use orderbook contract as referrer");
		vm.prank(user1);
		orderBook.placeOrderWithHint(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, 0, address(orderBook));

		assertEq(USDC.balanceOf(user1), 10000e6);
		assertEq(USDC.balanceOf(bank), 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);

		// any other referrer still works
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		assertEq(USDC.balanceOf(bank), 100e6);
	}

	// With no referrer, the taker still pays the full fee, the protocol gets its share,
	// and the referrer share is held for address(0), where nobody can withdraw it (effectively burned)
	function testZeroReferrerShareBurned() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 100);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 100);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 200e6);
		USDC.mint(user3, 200e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		// taker buys 100 EURT: 1 EURT fee, 0.5 to protocol, 0.5 held for address(0)
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, address(0));
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, address(0));
		assertEq(EURT.balanceOf(user3), 99e6);
		assertEq(USDC.balanceOf(user2), 100e6);
		assertEq(EURT.balanceOf(protocolFeeReceiver), 0.5e6);
		assertEq(orderBook.failedPaymentBalance(address(0), bank, address(EURT)), 0.5e6);
		assertEq(EURT.balanceOf(bank), 0.5e6);

		// taker sells 100 EURT: 1 USDC fee, 0.5 to protocol, 0.5 held for address(0)
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, address(0));
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, address(0));
		assertEq(USDC.balanceOf(user2), 199e6);
		assertEq(USDC.balanceOf(protocolFeeReceiver), 0.5e6);
		assertEq(orderBook.failedPaymentBalance(address(0), bank, address(USDC)), 0.5e6);
		assertEq(USDC.balanceOf(bank), 0.5e6);
	}

	// With the protocol fee at 20% of the market fee, the referrer gets the other 80%
	function testReferrerSplitWithCustomProtocolFee() public {
		vm.prank(protocolFeeReceiver);
		orderBook.updateProtocolFee(20);
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 100);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 100);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 200e6);
		USDC.mint(user3, 200e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		// taker buys 100 EURT: 1% fee = 1 EURT, 0.8 to referrer, 0.2 to protocol
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, referrer);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		assertEq(EURT.balanceOf(user3), 99e6);
		assertEq(EURT.balanceOf(referrer), 0.8e6);
		assertEq(EURT.balanceOf(protocolFeeReceiver), 0.2e6);

		// taker sells 100 EURT: 1% fee = 1 USDC, 0.8 to referrer, 0.2 to protocol
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6, referrer);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6, referrer);
		assertEq(USDC.balanceOf(user2), 199e6);
		assertEq(USDC.balanceOf(referrer), 0.8e6);
		assertEq(USDC.balanceOf(protocolFeeReceiver), 0.2e6);

		// everything was paid out, nothing left in the bank
		assertEq(EURT.balanceOf(bank), 0);
		assertEq(USDC.balanceOf(bank), 0);
	}

	// ---------- Dust maker refunds ----------

	// A partial fill that leaves a maker sell below the market minimum refunds the rest to the maker,
	// removes the order, and leaves the book working for the orders behind it
	function testDustMakerSellRefunded() public {
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		MatchingOrderBook.Side SELL = MatchingOrderBook.Side.SELL;
		EURT.mint(user2, 200e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		USDC.mint(user3, 1000e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		vm.prank(user2);
		uint128 dustId = orderBook.placeOrder(marketId, SELL, 100e6, 1e6);
		vm.prank(user2);
		uint128 nextId = orderBook.placeOrder(marketId, SELL, 100e6, 2e6);

		// buy 95 leaves 5 EURT, below the 10 EURT minimum, so the 5 is refunded
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 95e6, 1e6);
		assertEq(EURT.balanceOf(user3), 95e6);
		assertEq(USDC.balanceOf(user2), 95e6);
		assertEq(EURT.balanceOf(user2), 5e6);
		assertEq(orderBook.getOrder(marketId, SELL, dustId).baseQuantity, 0);
		assertEq(EURT.balanceOf(bank), 100e6);

		// the next order is now the head and is still fillable
		assertEq(orderBook.getFirstOrderId(marketId, SELL), nextId);
		assertEq(orderBook.getOrder(marketId, SELL, nextId).previousOrderId, 0);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 50e6, 2e6);
		assertEq(EURT.balanceOf(user3), 145e6);
		assertEq(orderBook.getOrder(marketId, SELL, nextId).baseQuantity, 50e6);
	}

	// Same on the buy side: a maker bid left below the quote minimum is refunded its remaining quote
	function testDustMakerBuyRefunded() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		MatchingOrderBook.Side BUY = MatchingOrderBook.Side.BUY;
		USDC.mint(user3, 1000e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user2, 200e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);

		vm.prank(user3);
		uint128 dustId = orderBook.placeOrder(marketId, BUY, 100e6, 1e6);
		vm.prank(user3);
		uint128 nextId = orderBook.placeOrder(marketId, BUY, 100e6, 0.5e6);

		// sell 95 leaves a bid worth 5 USDC, below the 10 USDC minimum, so the 5 USDC is refunded
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 95e6, 1e6);
		assertEq(USDC.balanceOf(user2), 95e6);
		assertEq(EURT.balanceOf(user3), 95e6);
		assertEq(USDC.balanceOf(user3), 1000e6 - 100e6 - 50e6 + 5e6);
		assertEq(orderBook.getOrder(marketId, BUY, dustId).baseQuantity, 0);
		assertEq(USDC.balanceOf(bank), 50e6);

		assertEq(orderBook.getFirstOrderId(marketId, BUY), nextId);
		assertEq(orderBook.getOrder(marketId, BUY, nextId).previousOrderId, 0);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 50e6, 0.5e6);
		assertEq(EURT.balanceOf(user3), 145e6);
		assertEq(orderBook.getOrder(marketId, BUY, nextId).baseQuantity, 50e6);
	}

	// A partial fill that leaves the maker at or above the minimum keeps the order on the book
	function testPartialFillAboveMinimumNotRefunded() public {
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 1, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		USDC.mint(user3, 100e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), 100e18);

		vm.prank(user2);
		uint128 askId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 90e6, 1e6);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.SELL, askId).baseQuantity, 10e6);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.SELL), askId);
		assertEq(EURT.balanceOf(user2), 0);
	}

	// placeOrderWithHint with a referrer on a 1% fee market (protocol 50%):
	// a resting order placed deep with a hint earns the referrer nothing, and taker orders through
	// placeOrderWithHint pay the referrer half the fee whether they fully fill or post a leftover
	function testPlaceOrderWithHintAndReferrerOnFeeMarket() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 1, 100);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 1, 100);
		MatchingOrderBook.Side SELL = MatchingOrderBook.Side.SELL;
		MatchingOrderBook.Side BUY = MatchingOrderBook.Side.BUY;
		EURT.mint(user2, 1000e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), type(uint).max);
		USDC.mint(user3, 1000e6);
		vm.prank(user3);
		USDC.approve(address(orderBook), type(uint).max);

		// asks at 1..10 and bids at 0.1..0.5, 10 EURT each
		uint128[] memory asks = new uint128[](11);
		for (uint i = 1; i <= 10; i++) {
			vm.prank(user2);
			asks[i] = orderBook.placeOrder(marketId, SELL, 10e6, i * 1e6);
		}
		uint128[] memory bids = new uint128[](6);
		for (uint i = 1; i <= 5; i++) {
			vm.prank(user3);
			bids[i] = orderBook.placeOrder(marketId, BUY, 10e6, i * 0.1e6);
		}

		// 1. resting ask at 7.5 with a hint at the 7 ask: lands between 7 and 8, no fill so no referral fee
		vm.prank(user2);
		uint128 deep = orderBook.placeOrderWithHint(marketId, SELL, 10e6, 7.5e6, asks[7], referrer);
		assertEq(orderBook.getOrder(marketId, SELL, deep).previousOrderId, asks[7]);
		assertEq(orderBook.getOrder(marketId, SELL, deep).nextOrderId, asks[8]);
		assertEq(EURT.balanceOf(referrer), 0);
		assertEq(USDC.balanceOf(referrer), 0);

		// 2. taker buys 15 EURT at up to 2.00 with a hint and a referrer. Fully fills (10 at 1, 5 at 2), so the hint
		// is never used. Fee 1% of 15 EURT = 0.15 EURT: 0.075 to referrer, 0.075 to protocol
		uint user3Usdc = USDC.balanceOf(user3);
		vm.prank(user3);
		uint128 id = orderBook.placeOrderWithHint(marketId, BUY, 15e6, 2e6, bids[1], referrer);
		assertEq(id, 0);
		assertEq(EURT.balanceOf(user3), 14.85e6);
		assertEq(user3Usdc - USDC.balanceOf(user3), 20e6); // 10 + 10, unused 10 refunded
		assertEq(EURT.balanceOf(referrer), 0.075e6);
		assertEq(EURT.balanceOf(protocolFeeReceiver), 0.075e6);
		assertEq(orderBook.getFirstOrderId(marketId, SELL), asks[2]);
		assertEq(orderBook.getOrder(marketId, SELL, asks[2]).baseQuantity, 5e6);

		// 3. taker sells 30 EURT at 0.4 with a referrer: fills the 0.5 and 0.4 bids (9 USDC), posts the
		// leftover 10 as the new best ask. Fee 1% of 9 USDC = 0.09 USDC: 0.045 to referrer, 0.045 to protocol
		uint user2Usdc = USDC.balanceOf(user2);
		vm.prank(user2);
		uint128 leftover = orderBook.placeOrderWithHint(marketId, SELL, 30e6, 0.4e6, 0, referrer);
		assertEq(USDC.balanceOf(user2) - user2Usdc, 8.91e6);
		assertEq(USDC.balanceOf(referrer), 0.045e6);
		assertEq(USDC.balanceOf(protocolFeeReceiver), 0.045e6);
		assertEq(orderBook.getOrder(marketId, SELL, leftover).baseQuantity, 10e6);
		assertEq(orderBook.getFirstOrderId(marketId, SELL), leftover);
		assertEq(orderBook.getOrder(marketId, SELL, leftover).nextOrderId, asks[2]);
		assertEq(orderBook.getFirstOrderId(marketId, BUY), bids[3]);
	}

	// ---------- Events ----------

	// A maker sell left below the 10 EURT minimum is removed and OrderRefunded reports the 5 EURT returned
	function testOrderRefundedEventSell() public {
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 1, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);

		vm.expectEmit(true, false, false, true, address(orderBook));
		emit OrderRefunded(orderId, address(EURT), 5e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 95e6, 1e6);
	}

	// A maker buy left below the 10 USDC minimum is removed and OrderRefunded reports the 5 USDC returned
	function testOrderRefundedEventBuy() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 10e6, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 10e6, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);

		vm.expectEmit(true, false, false, true, address(orderBook));
		emit OrderRefunded(orderId, address(USDC), 5e6);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 95e6, 1e6);
	}

	// When the leftover rounds to 0 quote, nothing is sent but OrderRefunded still fires so indexers see the removal
	function testOrderRefundedEventZeroAmount() public {
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 1, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		// bid 100 EURT at a price of 1 quote unit per EURT (100 units of USDC in total)
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1);

		// selling 99.5 leaves 0.5 EURT, worth 0 quote units after rounding
		vm.expectEmit(true, false, false, true, address(orderBook));
		emit OrderRefunded(orderId, address(USDC), 0);
		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 99.5e6, 1);
		assertEq(orderBook.getOrder(marketId, MatchingOrderBook.Side.BUY, orderId).baseQuantity, 0);
		assertEq(orderBook.getFirstOrderId(marketId, MatchingOrderBook.Side.BUY), 0);
	}

	// updateProtocolFee emits the new percent and endProtocolFee emits 0
	function testProtocolFeeChangedEvents() public {
		vm.expectEmit(false, false, false, true, address(orderBook));
		emit ProtocolFeeChanged(20);
		vm.prank(protocolFeeReceiver);
		orderBook.updateProtocolFee(20);

		vm.expectEmit(false, false, false, true, address(orderBook));
		emit ProtocolFeeChanged(0);
		vm.prank(protocolFeeReceiver);
		orderBook.endProtocolFee();
	}

	// A payment to a frozen maker emits PaymentFailed, and withdrawing it later emits WithdrawFailedPayment
	function testPaymentFailedAndWithdrawEvents() public {
		FreezableERC20 FRZ = new FreezableERC20("FRZ", "Freezable Token", 6);
		orderBook.createMarket(address(EURT), address(FRZ), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(FRZ), 1, 1, 0, 1);
		address bank = orderBook.getMarketDetails(marketId).bankAddress;
		EURT.mint(user2, 100e6);
		FRZ.mint(user3, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user3);
		FRZ.approve(address(orderBook), 100e18);

		vm.prank(user2);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		FRZ.freeze(user2);

		vm.expectEmit(true, true, true, true, address(orderBook));
		emit PaymentFailed(user2, bank, address(FRZ), 100e6);
		vm.prank(user3);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);

		FRZ.unfreeze(user2);
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit WithdrawFailedPayment(user2, bank, address(FRZ), 100e6);
		vm.prank(user2);
		orderBook.withdrawFailedPayment(bank, address(FRZ));
	}

	// createMarket emits the market settings, the cached base token decimals, and the new bank address
	function testMarketCreatedEvent() public {
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 10e6, 5e6, 1, 1000);
		// the bank is the next contract the order book deploys
		address expectedBank = vm.computeCreateAddress(address(orderBook), vm.getNonce(address(orderBook)));

		vm.expectEmit(true, false, false, true, address(orderBook));
		emit MarketCreated(marketId, address(EURT), address(USDC), 10e6, 5e6, 1, 1000, 6, expectedBank);
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 5e6, 1, 1000);
		assertEq(orderBook.getMarketDetails(marketId).bankAddress, expectedBank);
	}

	// A resting order emits OrderPlaced with its id, owner, market, side, size and price
	function testOrderPlacedEvent() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);

		uint128 expectedId = orderBook.orderCounter() + 1;
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderPlaced(expectedId, user2, marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		vm.prank(user2);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		assertEq(orderId, expectedId);

		expectedId = orderBook.orderCounter() + 1;
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderPlaced(expectedId, user1, marketId, MatchingOrderBook.Side.BUY, 50e6, 0.9e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 50e6, 0.9e6);
	}

	// With fee-on-transfer tokens, OrderPlaced reports what was actually posted:
	// the reduced size for a sell and the adjusted price for a buy
	function testOrderPlacedEventFeeOnTransfer() public {
		FeeOnTransferERC20 TAX = new FeeOnTransferERC20("TAX", "Taxed Token", 6, 100);
		TAX.mint(user2, 100e6);
		vm.prank(user2);
		TAX.approve(address(orderBook), 100e18);

		// TAX as base: selling 100 lands 99 in the bank
		orderBook.createMarket(address(TAX), address(USDC), 1, 1, 0, 1);
		bytes32 sellMarket = orderBook.getMarketId(address(TAX), address(USDC), 1, 1, 0, 1);
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderPlaced(orderBook.orderCounter() + 1, user2, sellMarket, MatchingOrderBook.Side.SELL, 99e6, 1e6);
		vm.prank(user2);
		orderBook.placeOrder(sellMarket, MatchingOrderBook.Side.SELL, 100e6, 1e6);

		// TAX as quote: a 100 EURT bid at 1.00 only lands 0.99 TAX per EURT, so the price is posted as 0.99
		TAX.mint(user3, 100e6);
		vm.prank(user3);
		TAX.approve(address(orderBook), 100e18);
		orderBook.createMarket(address(EURT), address(TAX), 1, 1, 0, 1);
		bytes32 buyMarket = orderBook.getMarketId(address(EURT), address(TAX), 1, 1, 0, 1);
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderPlaced(orderBook.orderCounter() + 1, user3, buyMarket, MatchingOrderBook.Side.BUY, 100e6, 0.99e6);
		vm.prank(user3);
		orderBook.placeOrder(buyMarket, MatchingOrderBook.Side.BUY, 100e6, 1e6);
	}

	// A taker that crosses two asks emits one OrderFill per maker, at each maker's price, then OrderPlaced
	// for the leftover it posts
	function testOrderFillEventsThenOrderPlaced() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		EURT.mint(user2, 200e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 ask1 = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);
		vm.prank(user2);
		uint128 ask2 = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1.1e6);

		// buy 250 at up to 1.20: fills 100 at 1.00 and 100 at 1.10, posts 50 at 1.20
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderFill(ask1, user2, user1, marketId, 100e6, 1e6);
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderFill(ask2, user2, user1, marketId, 100e6, 1.1e6);
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderPlaced(orderBook.orderCounter() + 1, user1, marketId, MatchingOrderBook.Side.BUY, 50e6, 1.2e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 250e6, 1.2e6);
	}

	// A taker that fills completely emits OrderFill for the partial maker fill and no OrderPlaced
	function testFullFillEmitsNoOrderPlaced() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		EURT.mint(user2, 100e6);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		uint128 askId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 100e6, 1e6);

		vm.recordLogs();
		vm.expectEmit(true, true, true, true, address(orderBook));
		emit OrderFill(askId, user2, user1, marketId, 40e6, 1e6);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 40e6, 1e6);
		assertEq(orderId, 0);

		Vm.Log[] memory logs = vm.getRecordedLogs();
		for (uint i = 0; i < logs.length; i++) {
			if (logs[i].emitter == address(orderBook)) {
				assertTrue(logs[i].topics[0] != OrderPlaced.selector, "full fill should not emit OrderPlaced");
			}
		}
	}

	function testOrderCanceledEvent() public {
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1);
		vm.prank(user1);
		uint128 orderId = orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 100e6, 1e6);

		vm.expectEmit(true, false, false, true, address(orderBook));
		emit OrderCanceled(orderId);
		vm.prank(user1);
		orderBook.cancelOrder(marketId, MatchingOrderBook.Side.BUY, orderId);
	}

	// Markets need minimums of at least 1 on both sides
	function testCreateMarketZeroMinimumsRevert() public {
		vm.expectRevert("baseMinimum must be atleast 1");
		orderBook.createMarket(address(EURT), address(USDC), 0, 1, 0, 1);
		vm.expectRevert("quoteMinimum must be atleast 1");
		orderBook.createMarket(address(EURT), address(USDC), 1, 0, 0, 1);
		orderBook.createMarket(address(EURT), address(USDC), 1, 1, 0, 1);
		assertTrue(orderBook.getMarketDetails(orderBook.getMarketId(address(EURT), address(USDC), 1, 1, 0, 1)).bankAddress != address(0));
	}
}
