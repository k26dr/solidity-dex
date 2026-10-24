# On-Chain Matching Engine in Solidity

The primary contract here is [MatchingOrderBook.sol](MatchingOrderBook.sol). 

Market creators can set custom taker fees and there is a referral system built in so that anyone can use this to make referral revenue. 

The taker fee is set during market creation. The fee is split between a referrer specified in each trade and the protocol. Frontends can use this to collect a fee on any trades executed on their platforms. By default, the protocol takes 50% of the fee revenue, but that number can be adjusted down to anywhere between 0%-50%. The referrer receives the rest.

It is a full on-chain spot exchange with on-chain matching and risk isolation. The funds for open orders and failed payments for each individual market are held in separate trustless contracts to prevent cross-contamination of risk.

There is a minimum post order size on markets that is configurable during market creation. Any orders below the minimum size are run as fill or kill operations that error out if the order doesn't fill in it's entirety. If a maker order is partially filled and the remaining amount is less than the base or quote minimum, the remainder of the maker order is refunded to the maker.  

A single base-quote token pair can have multiple markets with different post minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets. Supported token types include standard ERC20 and non-standard fee-for-transfer tokens. ERC1363 are supported with a transfer gas limit of 110k. Anything more than that and you will have to recover the token using `withdrawFailedPayment`. 

Rebasing tokens are not supported and there is currently no plan to do so. 

To improve order insertion efficiency for orders that go deep in the book, `placeOrderWithHint` can be used. An order ID can be passed in as a hint, and the insertion search begins from the hint instead of from the beginning of the book. This allows books to comfortably reach millions of orders in size instead of being restricted to insertions within 300-400 orders of the tip of the book. The `getOrderBookWithStartId` view function can be used to page through the orderbook and determine which order to use as a hint.

Token recovery in cases where a token contract freezes an address is also supported using `withdrawFailedPayment`. Example: USDC freezes an address. The funds get parked in the contract in risk isolation mode and can be accessed when the address has been unfrozen.

A frontend is under development. 
