import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"
import "@acton/types/transaction"

import "@contracts/messages"
import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    val pool = loadPool();
    val owner = poolOwner();

    val validator = promptValidatorAddress("VALIDATOR_ADDRESS", "Enter validator address:");
    val roundAllowance = roundAllowanceFromEnvOrPrompt();
    val value = promptCoins("ADD_VALIDATOR_VALUE", "Value to send with AddValidator (TON):", "250");
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;

    // Detect prior presence so we can distinguish a fresh add from a no-op duplicate.
    val poolDataBefore = pool.getPoolData();
    val validatorsBefore = lazy poolDataBefore.validators.load();
    val lookupBefore = validatorsBefore.validators.get(validator);
    val presentBefore = lookupBefore.isFound;

    println("Adding validator {} (roundAllowance={})", validator, roundAllowance);

    val res = pool.sendAddValidator(
        owner.address,
        queryId,
        validator,
        roundAllowance,
        null,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("AddValidator message was not accepted by network");
    }

    expectValidatorPresent(pool, validator);

    val info = pool.getValidatorInfo(validator);
    assertEqual(info.validator.roundParity, roundAllowance, "validator.roundParity");

    if (presentBefore) {
        // The contract refunds a duplicate add with ValidatorAlreadyExits.
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        assert(refundTx != null, 250);
        val refundMsg = refundTx.loadBody<RefundMessage>();
        assertEqual(refundMsg.context.errorCode as int, 601, "ValidatorAlreadyExits error code");
        println("OK: validator {} already present in pool {}", validator, pool.address);
    } else {
        println("OK: validator {} added to pool {}", validator, pool.address);
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
