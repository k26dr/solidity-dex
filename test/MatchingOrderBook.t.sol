// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../MatchingOrderBook.sol"; 
import "../libraries/MockERC20.sol"; 

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

	function setUp() public {
		USDC = new MockERC20("USDC", "USDC", 6);
		EURT = new MockERC20("EURT", "EURT", 6);
		WETH = new MockERC20("WETH", "WETH", 18);
		WBTC = new MockERC20("WBTC", "Wrapped Bitcoin", 8);
		AAPL = new MockERC20("AAPL", "Apple", 0);
		orderBook = new MatchingOrderBook();
		USDC.mint(user1, 10000e6);
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
	}

	function testPlaceOrderBeforeMarketCreation() public {
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.expectRevert("createMarket before placing an order on it"); 
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 115 * 1e6, 1e6);
	}

	function testCreateMarket() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
	}

	function testCreateMultipleMarketsForSamePair() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		orderBook.createMarket(address(EURT), address(USDC), 10e6, 10e6, 0, 0, address(0x0));
		orderBook.createMarket(address(EURT), address(USDC), 0, 100e6, 0, 0, address(0x0));
	}
	
	function testHackBankFailWithExternalAddress() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);
		vm.expectRevert("only owner can withdraw funds");
		Bank(marketDetails.bankAddress).withdrawTo(user1, address(0), 1e18);
	}

	function testCreateMarketTwiceAndFail() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.expectRevert("market has already been created");
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
	}
	
	function testPlaceOneOrderSell() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, 1e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 115e6, 11e5);
	}

	function testPlace500SellOrders() public {
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		USDC.mint(user1, 1000*1e18);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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

		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 1000e6);
		USDC.mint(user2, 1000e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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

		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		EURT.approve(address(orderBook), 100e18);
		USDC.mint(user1, 3300e6);
		EURT.mint(user2, 2500e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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

		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 3000e6);
		USDC.mint(user2, 4200e6);
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));

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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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

		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 1000e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 1000e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 1000e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 1000e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
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
		
		orderBook.createMarket(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(EURT), address(USDC), 0, 10e6, 0, 0, address(0x0));
		MatchingOrderBook.MarketDetails memory marketDetails = orderBook.getMarketDetails(marketId);

		vm.prank(user1);
		EURT.approve(address(orderBook), 100e18);
		vm.prank(user2);
		USDC.approve(address(orderBook), 100e18);
		EURT.mint(user1, 4000e6);
		USDC.mint(user2, 4000e6);
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.SELL, 1000e6, 1e6);
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

		orderBook.createMarket(address(WETH), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		USDC.approve(address(orderBook), 100e18);
		vm.prank(user2);
		WETH.approve(address(orderBook), 100e18);
		USDC.mint(user1, 3300e6);
		WETH.mint(user2, 25e17);
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 0, 10e6, 0, 0, address(0x0));
		vm.prank(user1);
		orderBook.placeOrder(marketId, MatchingOrderBook.Side.BUY, 1e18, 1000e6);
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

		orderBook.createMarket(address(WBTC), address(WETH), 1e3, 0, 0, 0, address(0x0));
		vm.prank(user1);
		WBTC.approve(address(orderBook), 25e7);
		vm.prank(user2);
		WETH.approve(address(orderBook), 48e18);
		WBTC.mint(user1, 25e7);
		WETH.mint(user2, 48e18);
		bytes32 marketId = orderBook.getMarketId(address(WBTC), address(WETH), 1e3, 0, 0, 0, address(0x0));
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
		orderBook.createMarket(address(AAPL), address(USDC), 0, 0, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(AAPL), address(USDC), 0, 0, 0, 0, address(0x0));
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
		orderBook.createMarket(address(WETH), address(USDC), 0, 0, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 0, 0, 0, 0, address(0x0));
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
			//uint fillBaseQuantity = 0;
			//uint fillQuoteQuantity = 0;
			//MatchingOrderBook.Side otherSide = side == MatchingOrderBook.Side.BUY ? MatchingOrderBook.Side.SELL : MatchingOrderBook.Side.BUY;
			//MatchingOrderBook.Order[] memory orders = orderBook.getOrderBook(marketId, otherSide, 100);
			// TODO: Verify balances after each trade
			vm.prank(user);
			orderBook.placeOrder(marketId, side, baseQuantity, price);
		}
	}

	function deleteFirstOrderUpdateHead() public {
		orderBook.createMarket(address(WETH), address(USDC), 0, 0, 0, 0, address(0x0));
		bytes32 marketId = orderBook.getMarketId(address(WETH), address(USDC), 0, 0, 0, 0, address(0x0));
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

}
