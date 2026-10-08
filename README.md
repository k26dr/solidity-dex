# On-Chain Matching Engine in Solidity

There are 2 versions of Solidity orderbooks in this repo. The primary one is [MatchingOrderBook.sol](MatchingOrderBook.sol). Market creators can set custom fees and fee receivers on that one so anyone can use this as a way to make revenue. There is a license agreement, and in some deployments, a protocol fee so that the copyright holders can receive a revshare. 

One is a scalable system for high-fee chains like Ethereum that allows for decentralized operation via an indexer that can be run locally or remotely: [Orderbook.sol](OrderBook.sol). There are no order minimums and the design optimizes gas to keep execution prices low.

The other uses an on-chain matching engine that consumes more gas but permits full on-chain matching. It's ideal for low-fee chains but in the current environment with low Ethereum fees it could be viable there as well: [MatchingOrderbook.sol](MatchingOrderBook.sol). 

There is a minimum post order size on markets in the matching version that is configurable during market creation. Any orders below the minimum size are run as fill or kill operations that error out if the order doesn't fill in it's entirety. A single base-quote token pair can have multiple markets with different order minimum sizes. This keeps the exchange flexible and allows us to get to a level where spam is no longer an issue. 

Both versions have a risk isolation system to prevent malicious tokens from attacking other markets, and have support for both regular ERC20 and non-standard fee-for-transfer tokens.  Rebasing tokens are not supported and there is currently no plan to do so. 

The Solidity code for both versions is complete. Frontends for both are still under development. Additionally an indexer for the non-matching version is also under development. 

The contract for the matching version is live and deployed on Base mainnet. Contract addresses will be added soon when mainnet testing is complete. 

# CLI For the non-matching orderbook

The non-matching orderbook requires a CLI to fill orders. It is still under development, but you can compile the existing version as such:

```
cd cli_go
go build
```

A binary called `dex` will be available in the `cli_go` folder.

# CLI Commands

### Help

```
$ ./dex help
Decentralized Exchange Command Line Interface.

Usage:
  dex [command]

Available Commands:
  config      Manage dex configuration
  help        Help about any command
  token       Interact with ERC20 tokens
  trade       Interact with the exchange order book
  wallet      Manage wallets

Flags:
  -h, --help   help for dex

Use "dex [command] --help" for more information about a command.
```

### Setting the Chain ID

By default the Chain ID is set to Ethereum mainnet (chainId: 1). To change it to a different network (example: arbitrum):

```
$ ./dex config chain-id 42161
Set chain_id: 42161
```

### Setting the Contract Address

In the future, we will have default contract addresses stored for many chains. 

For now, contract addresses have to be set manually. 

```
./dex config contract 0xc026deC188ef7D8B4742CE38E36f3C3BcD328E4C
```

### Setting an RPC

The RPC will default to http://localhost:8545 (WIP - for now set manually). To use a remote RPC: 

```
./dex config rpc https://rpc.flashbots.net
```

Unless you are using a local node, you will likely need a paid tier RPC to sync orderbooks.

### Create a Wallet

```
./dex wallet create
```

Follow the help text in the interactive prompts to set up a wallet.

### Other Wallet Commands

```
$ ./dex help wallet
Manage wallets

Usage:
  dex wallet [command]

Available Commands:
  balance     Show non-zero token balances for tracked tokens
  create      Create a new wallet
  delete      Delete one or more wallets from the keystore
  export      Export a wallet private key
  import      Import a wallet into the keystore
  list        List all wallets in the keystore
  terminate   Delete all wallets from the keystore

Flags:
  -h, --help   help for wallet

Use "dex wallet [command] --help" for more information about a command.
```

### Configuration

```
$ ./dex help config
Manage dex configuration

Usage:
  dex config [command]

Available Commands:
  chain-id    Set the Ethereum chain ID
  contract    Set the DEX contract address
  rpc         Set the Ethereum RPC URL
  show        Show dex configuration
  terminate   Delete the dex configuration file from disk
  token       Manage tracked ERC20 tokens

Flags:
  -h, --help   help for config

Use "dex config [command] --help" for more information about a command.
```

### Trading

```
$ ./dex trade order
Manage orders

Usage:
  dex trade order [command]

Available Commands:
  cancel      Cancel an order you own
  count       Get total order counter
  fill        Fill an existing order
  get         Get a specific order
  place       Place a new order

Flags:
  -h, --help   help for order

Use "dex trade order [command] --help" for more information about a command.
```
