<p align="center">
  <img src=".github/logo.png" alt="Verora" width="88" />
</p>

<p align="center">
  Smart contracts for Verora - Decentralized AI Oracle Network.
</p>

<p align="center">
  <a href="https://book.getfoundry.sh/"><img src="https://img.shields.io/badge/Foundry-1C1C1C?logo=foundry&logoColor=white" alt="Foundry" /></a>
  <a href="https://soliditylang.org/"><img src="https://img.shields.io/badge/Solidity-363636?logo=solidity&logoColor=white" alt="Solidity" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
</p>

## Contracts

| Contract | Description |
|----------|-------------|
| `AgentRegistry` | Register and manage AI agents |
| `StakingPool` | Share-based ETH staking with rewards, unbonding, and slashing |
| `PaymentRouter` | Split settled query payments between agents, stakers, and the treasury |
| `ReputationManager` | Track agent reputation scores |
| `QueryConsumer` | Query escrow, signed responses, settlement, expiry, and refunds |
| `Treasury` | Manage protocol funds |

## Tech Stack

- **Framework**: Foundry
- **Language**: Solidity
- **Libraries**: OpenZeppelin

## Getting Started

```bash
forge install
forge build
forge test        # unit, integration, regression, and invariant tests
forge fmt --check
```

## Deploy

Target: **Ethereum Sepolia** (chain 11155111), release `v0.1.0`.

The deploy script takes the signer from the forge CLI. The deployer key lives in an encrypted
`cast wallet` keystore and is selected with `--account`; never put a private key in an env var or a
command-line flag. The script writes the addresses, deployer, start block, and version to
`deployments/<chainId>.json`, which the API, SDK, and app consume.

```bash
# One-time: import the deployer key into an encrypted keystore (prompts for the key and a password)
cast wallet import verora-deployer --interactive

export SEPOLIA_RPC_URL=https://...     # Ethereum Sepolia RPC endpoint
export ETHERSCAN_API_KEY=...           # Etherscan V2 key, for source verification
export FINALIZER=0x...                 # oracle signer address (needs gas only)
export OWNER=0x...                     # optional: multisig that becomes owner (must acceptOwnership)

forge script script/Deploy.s.sol:Deploy \
  --rpc-url sepolia --account verora-deployer --sender <deployer-address> \
  --broadcast --verify --skip-simulation --slow --gas-estimate-multiplier 110
```

Contract creation on Sepolia costs far more gas than forge's local simulation assumes, so the flags matter:
`--skip-simulation` makes forge take every gas limit from the node's `eth_estimateGas`, `--slow` waits for
each transaction before estimating the next (the wiring calls need the contracts to exist), and the 110%
multiplier keeps the largest deployment (QueryConsumer, ~14.7M gas) under the 16,777,216 per-transaction
gas cap; the default 130% would exceed it. QueryConsumer links two libraries, `QueryBook` and
`QuerySettlement`, which forge deploys first through the deterministic CREATE2 factory and verifies along
with the contracts.

Optional parameters: `MIN_STAKE` (wei, default 0.01 ETH), `UNSTAKING_PERIOD` (seconds, default 7 days),
`MIN_PAYMENT_PER_AGENT` (wei, default 0.0001 ETH).

When `OWNER` differs from the deployer, ownership is transferred in two steps: the owner must call
`acceptOwnership()` on every contract before it controls them.

`deployments/11155111.json` is committed after the Sepolia deployment; `broadcast/` and the local Anvil
manifest (`deployments/31337.json`) stay untracked.

## Exporting ABIs

```bash
node script/export-abis.mjs ../verora-api/src/chain/abis.ts ../verora-sdk/src/abis.ts ../verora-app/src/config/abis.ts
```

## Network

Testnet target: **Ethereum Sepolia** (chain 11155111). Ethereum mainnet requires an external audit first.

v0.1.0 is deployed on Sepolia from start block `11900598` (full manifest in [`deployments/11155111.json`](deployments/11155111.json)):

| Contract | Address |
| --- | --- |
| AgentRegistry | [`0x701A2a74fcc92b3310c5F9c9Fc2dd03c3C6e45cc`](https://sepolia.etherscan.io/address/0x701A2a74fcc92b3310c5F9c9Fc2dd03c3C6e45cc) |
| QueryConsumer | [`0x359b07841C0Add13533D0032187E865290828Cd2`](https://sepolia.etherscan.io/address/0x359b07841C0Add13533D0032187E865290828Cd2) |
| StakingPool | [`0xD60936Bc2E8653340A43Cf711Bd04b3d894B945f`](https://sepolia.etherscan.io/address/0xD60936Bc2E8653340A43Cf711Bd04b3d894B945f) |
| ReputationManager | [`0x390833B00F624d281a10D82F0139E8004f5A428B`](https://sepolia.etherscan.io/address/0x390833B00F624d281a10D82F0139E8004f5A428B) |
| PaymentRouter | [`0x8552f8eb6cbAb35B3e917d17fAa6CCac34f595a8`](https://sepolia.etherscan.io/address/0x8552f8eb6cbAb35B3e917d17fAa6CCac34f595a8) |
| Treasury | [`0x7C95624609896A74C5057353b167A2C55b2151AD`](https://sepolia.etherscan.io/address/0x7C95624609896A74C5057353b167A2C55b2151AD) |
| QueryBook (library) | [`0x5fB0100dd2673138624633CAA5f0Fff04b8F38e6`](https://sepolia.etherscan.io/address/0x5fB0100dd2673138624633CAA5f0Fff04b8F38e6) |
| QuerySettlement (library) | [`0x83BcB34BaC98802fCb92B33AE746ff7727A1C006`](https://sepolia.etherscan.io/address/0x83BcB34BaC98802fCb92B33AE746ff7727A1C006) |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contact

Project Link: [https://github.com/pzzaworks/verora-contracts](https://github.com/pzzaworks/verora-contracts)
