# On-Chain Matching Engine in Solidity

The primary contract here is [MatchingOrderBook.sol](MatchingOrderBook.sol). 

Market creators can set custom taker fees and there is a referral system built in so that anyone can use this to make referral revenue. 

The taker fee is set during market creation. The fee is split between a referrer specified in each trade and the protocol. Frontends can use this to collect a fee on any trades executed on their platforms. By default, the protocol takes 50% of the fee revenue, but that number can be adjusted down to anywhere between 0%-50%. The referrer receives the rest.

It is a full on-chain spot exchange with on-chain matching and risk isolation. The funds for open orders and failed payments for each individual market are held in separate trustless contracts to prevent cross-contamination of risk.

There is a minimum post order size on markets that is configurable during market creation. Any orders below the minimum size are run as immediate or cancel operations. Any unfilled funds are returned to the user. If a maker order is partially filled and the remaining amount is less than the base or quote minimum, the remainder of the maker order is refunded to the maker.  

A single base-quote token pair can have multiple markets with different post minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets. Supported token types include standard ERC20 and non-standard fee-for-transfer tokens. ERC1363 are supported with a transfer gas limit of 110k. Anything more than that and you will have to recover the token using `withdrawFailedPayment`. 

Rebasing tokens are not supported and there is currently no plan to do so. 

To improve order insertion efficiency for orders that go deep in the book, `placeOrderWithHint` can be used. An order ID can be passed in as a hint, and the insertion search begins from the hint instead of from the beginning of the book. This allows books to comfortably reach millions of orders in size instead of being restricted to insertions within 300-400 orders of the tip of the book. The `getOrderBookWithStartId` view function can be used to page through the orderbook and determine which order to use as a hint.

Token recovery in cases where a token contract freezes an address is also supported using `withdrawFailedPayment`. Example: USDC freezes an address. The funds get parked in the contract in risk isolation mode and can be accessed when the address has been unfrozen.

Currently there is an issue with DEX where submitting a specific type of transaction on taker buys can allow you to steal one quote unit at a time. If the gas fee to steal a single unit ever goes below the price of a single quote unit this attack would be profitable. Most tokens have plenty of precision so this is not an issue, but if any token were to have low precision, say a minimum quote unit with a value of more than $0.0001 (very much in the realm of possibility), this attack could become viable. WBTC is a candidate for something that could be attacked like this. We are working on a fix, and will patch this bug before deploying on mainnet.

There is a frontend that goes with these smart contracts at [https://github.com/nitric/zigzag](https://github.com/nitric/zigzag). 

## ABI


### Creating Markets

```
// baseMinimum and quoteMinimum are minimum sizes to leave an order on the book
// sizes below those numbers are run as immediate-or-cancel orders
// partially filled orders that go below those thresholds are evicted from the book and the remaining amounts are refunded to the maker
// feeNumerator and feeDenominator are both for taker fees. maker fees are always 0. 
createMarket(address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator) returns (bytes32 marketId)
```

### Placing Orders

```
// For markets with no fee, or if you would like to see the market fee burned, you can place orders without a referrer
placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price) external payable returns (uint128 orderId) 

// referrer gets (100 - protocolFeePercent)% of any taker fee for the market
placeOrder(bytes32 marketId, Side side, uint baseQuantity, uint price, address referrer) external payable returns (uint128 orderId) 

// if you want to place an order with a hint and no referrer
placeOrderWithHint(bytes32 marketId, Side side, uint baseQuantity, uint price, uint128 hintOrderId, bool revertOnBadHint) public payable returns (uint128 orderId)

// placeOrder function with hint
// to place orders further back in the book, the hintOrderId can be used to specify an order ID to start iterating at
// if the placement of the hint order is further in the book than the order should be placed, 
// it will either fail with an error if revertOnBadHint is set to true or run as a normal insert if revertOnBadHint is set false
// set hintOrderId = 0 if you don't want to include a hint
// The recommended behavior for revertOnBadHint is true to save gas
// If you want to place hints on orders close to the front of a book (not that you necessarily should, front of the book orders can be run without a hint)
// you can set this to false as a convenience so that if the hint order gets filled, your order runs as a normal insert
// referrer gets (100 - protocolFeePercent)% of any taker fee for the market
placeOrderWithHint(bytes32 marketId, Side side, uint baseQuantity, uint price, uint128 hintOrderId, bool revertOnBadHint, address referrer) public payable returns (uint128 orderId)
```

### Canceling Orders

```
cancelOrder(bytes32 marketId, Side side, uint128 orderId) 
```

### Failed Payments

Payments can fail if a user's address contains some kind of post-payment logic that uses too much gas, or if a token issuer freezes an address. There is an internal process for recovering funds that failed to send properly. Users can only withdraw failed payments into their own address.

```
withdrawFailedPayment(address payable bankAddress, address token) 

// To view failed payment balances
failedPaymentBalance(address user, address bank, address token) external view returns (uint)
```

### Return Structs

Many view functions return Order structs. Here's the format of the Order struct.

```
struct Order {
    address user;
    uint baseQuantity;
    uint price;
    uint128 nextOrderId;
    uint128 previousOrderId;
}
```

`getMarketDetails` returns market information. The return struct is as such:

```
struct MarketDetails {
    address baseToken;
    address quoteToken;
    uint baseMinPostSize;
    uint quoteMinPostSize;
    uint feeNumerator;
    uint feeDenominator;
    uint baseTokenDecimals;
    address payable bankAddress;
}
```

### View Functions

```
getMarketId(address baseToken, address quoteToken, uint baseMinimum, uint quoteMinimum, uint feeNumerator, uint feeDenominator) public pure returns (bytes32)

getMarketDetails(bytes32 marketId) public view returns (MarketDetails memory)

getOrder(bytes32 marketId, Side side, uint128 orderId) external view returns (Order memory)

getFirstOrderId(bytes32 marketId, Side side) external view returns (uint128 orderId)

// same as getOrderBookWithStartId but starting at the front of the book
getOrderBook(bytes32 marketId, Side side, uint depth) external view returns (Order[] memory)

// get an orderbook starting at a specific order id
getOrderBookWithStartId(bytes32 marketId, Side side, uint depth, uint128 startOrderId) public view returns (Order[] memory) 

```




