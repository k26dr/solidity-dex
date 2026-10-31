pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../MatchingOrderBook.sol";
import "./FreezableERC20.sol";

contract ZZNativeProbe is Test {
	MatchingOrderBook book;
	FreezableERC20 USDC;
	address alice = address(0xA11CE);
	address bob = address(0xB0B);
	function setUp() public {
		book = new MatchingOrderBook(payable(address(0xBEEF)), 50);
		USDC = new FreezableERC20("USDC", "USDC", 6);
		vm.deal(alice, 100 ether); vm.deal(bob, 100 ether);
		USDC.mint(alice, 1e12); USDC.mint(bob, 1e12);
		vm.prank(alice); USDC.approve(address(book), type(uint).max);
		vm.prank(bob); USDC.approve(address(book), type(uint).max);
	}
	function testCreateNativeBaseMarket() public {
		book.createMarket(address(0), address(USDC), 1, 1, 0, 1);
	}
	function testNativeQuoteBuy() public {
		book.createMarket(address(USDC), address(0), 1, 1, 0, 1);
		bytes32 m = book.getMarketId(address(USDC), address(0), 1, 1, 0, 1);
		// buy 1 USDC (6 dp) at price 1e18 wei per USDC => quote = 1e6 * 1e18 / 1e6 = 1e18
		vm.prank(alice);
		book.placeOrder{value: 1e18}(m, MatchingOrderBook.Side.BUY, 1e6, 1e18);
	}
	function testNativeQuoteSellThenBuyFills() public {
		book.createMarket(address(USDC), address(0), 1, 1, 0, 1);
		bytes32 m = book.getMarketId(address(USDC), address(0), 1, 1, 0, 1);
		vm.prank(bob);
		book.placeOrder(m, MatchingOrderBook.Side.SELL, 1e6, 1e18);
		vm.prank(alice);
		book.placeOrder{value: 1e18}(m, MatchingOrderBook.Side.BUY, 1e6, 1e18);
	}
}
