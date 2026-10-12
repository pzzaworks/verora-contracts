// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Deploy
 * @author Berke (pzzaworks)
 * @notice Deploy and wire the Verora contracts
 * @dev Implements a keystore-signed deployment that writes a versioned manifest to deployments/<chainId>.json.
 *      The signer comes from the forge CLI (`--account <keystore>` or `--ledger`; on local Anvil
 *      `--unlocked --sender <account>`), never from a private key in an env var or flag.
 *      Configuration (all optional except FINALIZER):
 *      - FINALIZER: oracle address authorized to finalize queries (required)
 *      - OWNER: final owner of every contract, e.g. a multisig (default: deployer). Ownership uses a 2-step
 *        transfer, so OWNER must call `acceptOwnership()` on each contract afterwards.
 *      - MIN_STAKE (wei, default 0.01 ether), UNSTAKING_PERIOD (seconds, default 7 days),
 *        MIN_PAYMENT_PER_AGENT (wei, default 0.0001 ether)
 *      QueryConsumer links the QueryBook and QuerySettlement libraries; forge deploys them first (through the
 *      deterministic CREATE2 factory) and `--verify` verifies them with the linking info. Broadcast with
 *      `--skip-simulation --slow --gas-estimate-multiplier 110` so every gas limit comes from the node's own
 *      `eth_estimateGas` (local simulation misprices contract creation on Sepolia) and stays under the
 *      EIP-7825 per-transaction gas cap, with each transaction mined before the next one is estimated.
 */
import {Script, console2} from "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {ReputationManager} from "../src/ReputationManager.sol";
import {StakingPool} from "../src/StakingPool.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {QueryConsumer} from "../src/QueryConsumer.sol";
import {Treasury} from "../src/Treasury.sol";

contract Deploy is Script {
    /// @notice Protocol version recorded in the deployment manifest
    string internal constant VERSION = "0.1.0";

    struct Config {
        address deployer;
        address owner;
        address finalizer;
        uint256 minStake;
        uint256 unstakingPeriod;
        uint256 minPaymentPerAgent;
    }

    struct Deployment {
        Treasury treasury;
        AgentRegistry agentRegistry;
        StakingPool stakingPool;
        ReputationManager reputationManager;
        PaymentRouter paymentRouter;
        QueryConsumer queryConsumer;
    }

    function run() external returns (Deployment memory d) {
        vm.startBroadcast();

        Config memory config = _loadConfig(msg.sender);
        d = _deploy(config);
        _wire(d, config);
        _transferOwnership(d, config);

        vm.stopBroadcast();

        _writeManifest(d, config);
        _log(d, config);
    }

    function _loadConfig(address deployer) internal view returns (Config memory config) {
        config.deployer = deployer;
        config.owner = vm.envOr("OWNER", deployer);
        config.finalizer = vm.envAddress("FINALIZER");
        config.minStake = vm.envOr("MIN_STAKE", uint256(0.01 ether));
        config.unstakingPeriod = vm.envOr("UNSTAKING_PERIOD", uint256(7 days));
        config.minPaymentPerAgent = vm.envOr("MIN_PAYMENT_PER_AGENT", uint256(0.0001 ether));

        require(config.owner != address(0), "OWNER is zero");
        require(config.finalizer != address(0), "FINALIZER is zero");
    }

    function _deploy(Config memory config) internal returns (Deployment memory d) {
        address deployer = config.deployer;

        d.treasury = new Treasury(deployer);
        d.agentRegistry = new AgentRegistry(deployer);
        d.stakingPool = new StakingPool(
            deployer, address(d.agentRegistry), address(d.treasury), config.minStake, config.unstakingPeriod
        );
        d.reputationManager = new ReputationManager(deployer, address(d.agentRegistry));
        d.paymentRouter =
            new PaymentRouter(deployer, address(d.agentRegistry), address(d.stakingPool), address(d.treasury));
        d.queryConsumer = new QueryConsumer(
            deployer,
            address(d.agentRegistry),
            address(d.reputationManager),
            address(d.paymentRouter),
            config.minPaymentPerAgent
        );
    }

    function _wire(Deployment memory d, Config memory config) internal {
        d.agentRegistry.setAuthorizedSlasher(address(d.stakingPool), true);
        d.reputationManager.setAuthorizedRecorder(address(d.queryConsumer), true);
        d.paymentRouter.setQueryConsumer(address(d.queryConsumer));
        d.queryConsumer.setAuthorizedFinalizer(config.finalizer, true);

        // Fail the run before the manifest is written if any link is missing
        require(d.agentRegistry.authorizedSlashers(address(d.stakingPool)), "slasher not wired");
        require(d.reputationManager.authorizedRecorders(address(d.queryConsumer)), "recorder not wired");
        require(d.paymentRouter.queryConsumer() == address(d.queryConsumer), "router not wired");
        require(d.queryConsumer.authorizedFinalizers(config.finalizer), "finalizer not wired");
    }

    function _transferOwnership(Deployment memory d, Config memory config) internal {
        if (config.owner == config.deployer) return;

        d.treasury.transferOwnership(config.owner);
        d.agentRegistry.transferOwnership(config.owner);
        d.stakingPool.transferOwnership(config.owner);
        d.reputationManager.transferOwnership(config.owner);
        d.paymentRouter.transferOwnership(config.owner);
        d.queryConsumer.transferOwnership(config.owner);
    }

    function _writeManifest(Deployment memory d, Config memory config) internal {
        string memory key = "deployment";
        vm.serializeString(key, "version", VERSION);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "startBlock", block.number);
        vm.serializeAddress(key, "deployer", config.deployer);
        vm.serializeAddress(key, "owner", config.owner);
        vm.serializeAddress(key, "finalizer", config.finalizer);
        vm.serializeAddress(key, "treasury", address(d.treasury));
        vm.serializeAddress(key, "agentRegistry", address(d.agentRegistry));
        vm.serializeAddress(key, "stakingPool", address(d.stakingPool));
        vm.serializeAddress(key, "reputationManager", address(d.reputationManager));
        vm.serializeAddress(key, "paymentRouter", address(d.paymentRouter));
        string memory json = vm.serializeAddress(key, "queryConsumer", address(d.queryConsumer));

        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
    }

    function _log(Deployment memory d, Config memory config) internal pure {
        console2.log("Version:           ", VERSION);
        console2.log("Deployer:          ", config.deployer);
        console2.log("Treasury:          ", address(d.treasury));
        console2.log("AgentRegistry:     ", address(d.agentRegistry));
        console2.log("StakingPool:       ", address(d.stakingPool));
        console2.log("ReputationManager: ", address(d.reputationManager));
        console2.log("PaymentRouter:     ", address(d.paymentRouter));
        console2.log("QueryConsumer:     ", address(d.queryConsumer));
        console2.log("Finalizer:         ", config.finalizer);
        if (config.owner != config.deployer) {
            console2.log("Pending owner (must acceptOwnership on every contract):", config.owner);
        }
    }
}
