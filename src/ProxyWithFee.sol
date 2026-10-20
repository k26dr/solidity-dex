// Copyright © 2026 Kedar Iyer
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// DEPRECATED: DO NOT USE ANY LONGER THIS WAS FOR THE OLD ORDERBOOK CONTRACT WITH RACE CONDITIONS

pragma solidity ^0.8.20;

import "../OrderBook.sol";
import "../libraries/SafeERC20.sol";

using SafeERC20 for IERC20;

contract ProxyWithFee {
	uint FEE_NUMERATOR;
	uint FEE_DENOMINATOR;
	address immutable ORDERBOOK_CONTRACT_ADDRESS; 
	address immutable owner; 

	constructor(uint fee_numerator, uint fee_denominator, address orderbook_contract, address _owner) {
		FEE_NUMERATOR = fee_numerator;
		FEE_DENOMINATOR = fee_denominator;
		ORDERBOOK_CONTRACT_ADDRESS = orderbook_contract;
		owner = _owner;
	}

	function enableToken(address token) external {
		IERC20(token).approve(ORDERBOOK_CONTRACT_ADDRESS, type(uint256).max);
	}

	function fillOrderWithFee(uint orderId, address baseToken, address quoteToken, uint baseQuantity) external payable {
		OrderBook orderBook = OrderBook(ORDERBOOK_CONTRACT_ADDRESS);
		OrderBook.Order memory order = orderBook.getorder(baseToken, quoteToken, orderId);

		(bool decimalCallSuccess, uint8 quoteTokenDecimals) = IERC20(quoteToken).tryGetDecimals();
		require(decimalCallSuccess, "failed to get decimals for token");
		uint quoteQuantity = baseQuantity * order.price / 10**quoteTokenDecimals;

		IERC20 quoteTokenIERC20 = IERC20(quoteToken);
		IERC20 baseTokenIERC20 = IERC20(baseToken);

		// Filler is buying - sending quote token, receiving base token
		if (order.side == OrderBook.Side.SELL) {
			if (quoteToken != address(0)) {
				quoteTokenIERC20.safeTransferFrom(msg.sender, address(this), quoteQuantity);
			}
			orderBook.fillOrder{value:msg.value}(orderId, baseToken, quoteToken, baseQuantity);
			uint baseBalance = baseTokenIERC20.balanceOf(address(this));
			uint fee = baseBalance * FEE_NUMERATOR / FEE_DENOMINATOR;
			baseTokenIERC20.safeTransfer(msg.sender, baseBalance - fee);
		} 

		// Filler is selling - sending base token, receiving quote token
		else {
			if (baseToken != address(0)) {
				baseTokenIERC20.safeTransferFrom(msg.sender, address(this), quoteQuantity);
			}
			orderBook.fillOrder{value:msg.value}(orderId, baseToken, quoteToken, baseQuantity);
			uint quoteBalance = quoteTokenIERC20.balanceOf(address(this));
			uint fee = quoteBalance * FEE_NUMERATOR / FEE_DENOMINATOR;
			quoteTokenIERC20.safeTransfer(msg.sender, quoteBalance - fee);
		}
	}

	function updateFee(uint fee_numerator, uint fee_denominator) external {
		require(msg.sender == owner, "only owner can update fee");
		FEE_NUMERATOR = fee_numerator;
		FEE_DENOMINATOR = fee_denominator;
	}

	function withdrawToken(address token) external {
		require(msg.sender == owner, "only owner can withdraw");
		if (token == address(0)) {
			(bool ok,) = payable(owner).call{value:address(this).balance}("");
			require(ok, "eth transfer failed");
		}
		else {
			IERC20 tokenIERC20 = IERC20(token);
			tokenIERC20.safeTransfer(owner, tokenIERC20.balanceOf(address(this)));
		}
	}
}
