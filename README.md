# On-Chain Matching Engine in Solidity

There are 2 versions of Solidity orderbooks in this repo. The primary one is [MatchingOrderBook.sol](MatchingOrderBook.sol). 

Market creators can set custom fees and fee receivers on that one so anyone can use this as a way to make revenue. There is a license agreement, and in some deployments, a protocol fee so that the copyright holders can receive a revshare. 

It is a full on-chain spot exchange with on-chain matching and risk isolation. 

There is a minimum post order size on markets that is configurable during market creation. Any orders below the minimum size are run as fill or kill operations that error out if the order doesn't fill in it's entirety. A single base-quote token pair can have multiple markets with different order minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets, and have support for both regular ERC20 and non-standard fee-for-transfer tokens.  Rebasing tokens are not supported and there is currently no plan to do so. 

A frontend is under development. 

# Non-matching version

The non-matching version is a scalable system for high-fee chains like Ethereum that allows for decentralized operation via an indexer that can be run locally or remotely: [Orderbook.sol](OrderBook.sol). There are no order minimums and the design optimizes gas to keep execution prices low.
