import "@acton/env"
import "@acton/fmt"
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
    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);
    val owner = poolOwner();

    val validator = promptNewValidatorAddress(
        "VALIDATOR_ADDRESS",
        "Enter validator address to add:",
    );
    val roundAllowance = roundAllowanceFromEnvOrPrompt();
    val limit = promptValidatorLimit();
    val value = promptCoins("ADD_VALIDATOR_VALUE", "Value to send with AddValidator (TON):", "250");
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;

    // Detect prior presence so we can distinguish a fresh add from a no-op duplicate.
    val poolDataBefore = pool.getPoolData();
    val validatorsBefore = lazy poolDataBefore.validators.load();
    val lookupBefore = validatorsBefore.validators.get(validator);
    val presentBefore = lookupBefore.isFound;

    println("Adding validator {} (roundAllowance={})", validator, roundAllowance);

    confirmSend(
        format(
            "Add validator\n  pool:           {}\n  validator:      {}\n  round allowance: {}\n  limit:          {}\n  value:          {:gram}",
            pool.address,
            validator,
            roundAllowance,
            limit == null ? "none (uses global)" : format("{}", limit),
            value,
        ),
    );

    val res = pool.sendAddValidator(
        owner.address,
        queryId,
        validator,
        roundAllowance,
        limit,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("AddValidator message was not accepted by network");
    }

    expectValidatorPresent(pool, validator);

    // Read the validator's roundParity from the persisted validators cell
    // (accounting for the main validator) instead of get_validator_info, which
    // is unreliable off-chain due to configParam(34) dependency.
    val rec = lookupValidatorRecord(pool, validator);
    if (rec == null) {
        Assert.fail(
            format(
                "Validator {} was not found in pool {} after AddValidator",
                validator,
                pool.address,
            ),
        );
    }
    assertEqual(rec!.roundParity, roundAllowance, "validator.roundParity");

    if (presentBefore) {
        // The contract refunds a duplicate add with ValidatorAlreadyExits.
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        if (refundTx == null) {
            Assert.fail(
                format(
                    "Validator {} was already present but no ValidatorAlreadyExits refund was observed",
                    validator,
                ),
            );
        }
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
