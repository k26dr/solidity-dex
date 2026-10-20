# On-Chain Matching Engine in Solidity

The primary contract here is [MatchingOrderBook.sol](MatchingOrderBook.sol). 

Market creators can set custom fees and fee receivers on that one so anyone can use this as a way to make revenue. There is a protocol fee built in that by default takes 50% of the fee, and can be set anywhere between 0 and 50% of the overall market fee. 

It is a full on-chain spot exchange with on-chain matching and risk isolation. 

There is a minimum post order size on markets that is configurable during market creation. Any orders below the minimum size are run as fill or kill operations that error out if the order doesn't fill in it's entirety. A single base-quote token pair can have multiple markets with different order minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets. Supported token types include ERC20, ERC1363 payable tokens, and non-standard fee-for-transfer tokens.  Rebasing tokens are not supported and there is currently no plan to do so. 

Token recovery in cases where a token contract freezes an address is also supported. 

A frontend is under development. 

# Non-matching version

The non-matching version [OrderBook.sol](OrderBook.sol) is deprecated and has too many race condition issues. It was a test from the past and is left in the repo for legacy purposes. It wasn't audited and might have issues with draining ETH. Don't use it. It's a relic. 
