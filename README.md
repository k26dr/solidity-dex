# On-Chain Matching Engine in Solidity

The primary contract here is [MatchingOrderBook.sol](MatchingOrderBook.sol). 

Market creators can set custom fees and fee receivers so anyone can use this as a way to make revenue. There is a protocol fee built in that by default takes 50% of the fee, and can be set anywhere between 0 and 50% of the overall market fee. 

It is a full on-chain spot exchange with on-chain matching and risk isolation. 

There is a minimum post order size on markets that is configurable during market creation. Any orders below the minimum size are run as fill or kill operations that error out if the order doesn't fill in it's entirety. A single base-quote token pair can have multiple markets with different post minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets. Supported token types include standard ERC20 and non-standard fee-for-transfer tokens. ERC1363 are supported with a transfer gas limit of 110k. Anything more than that and you will have to recover the token using `withdrawFailedPayment`. 

Rebasing tokens are not supported and there is currently no plan to do so. 

Token recovery in cases where a token contract freezes an address is also supported using `withdrawFailedPayment`. Example: USDC freezes an address. The funds get parked in the contract in risk isolation mode and can be accessed when the address has been unfrozen.

A frontend is under development. 
