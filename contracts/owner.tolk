import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/opcode"
import "@contracts/utils"
import "@contracts/validators"
import "types"

type OwnerMessages =
    | AddValidator
    | UpdateLimits
    | AddValidator
    | RemoveValidator
    | OwnerWithdrawal

fun processOwnerAction(msgSlice: slice, storage: Storage, sender: address, value: coins) {
    val msg = lazy OwnerMessages.fromSlice(msgSlice);
    var handled = true;
    match (msg) {
        AddValidator => {
            try {
                assert(sender == storage.owner, ErrorsPool.NotOwner);
                var validators = lazy storage.validators.load();

                if (msg.limits != null) {
                    validators.assertValidatorLimit(msg.limits);
                }

                var newValidator: Validator = {
                    usageState: 0,
                    roundParity: msg.roundAllowance,
                    limit: msg.limits,
                    refundAmount: 0,
                };

                val nRounds = max(msg.roundAllowance as int - 1, 1);
                val reserveAmount = nRounds * getMaxPunishmentInt(validators.minTonPerValidator);
                val valueLeft = value - NEW_VALIDATOR_FEE - reserveAmount;

                reserveGramsOnBalance(reserveAmount, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE);

                newValidator.deployProxy(msg.validator, storage.owner, valueLeft, msg.queryId);
                val newAdded = validators.validators.addIfNotExists(msg.validator, newValidator);

                assert(newAdded, ErrorsPool.ValidatorAlreadyExits);
                validators.activeValidators += 1;
                assert(validators.activeValidators <= (1 << 7), ErrorsPool.TooManyValidators);

                storage.validators = validators.toCell();
                storage.save();

                refundError(
                    sender,
                    {
                        op: opcode<AddValidator>(),
                        queryId: msg.queryId,
                        errorCode: 0,
                    },
                    SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
                );
            } catch (e) {
                refundError(
                    sender,
                    {
                        op: opcode<AddValidator>(),
                        queryId: msg.queryId,
                        errorCode: e,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
            }
        }
        RemoveValidator => {
            try {
                assert(sender == storage.owner, ErrorsPool.NotOwner);
                var validators = lazy storage.validators.load();
                assert(msg.validator !=
                validators.mainValidatorAddress, ErrorsPool.MainValidatorCantBeRemoved);
                val validatorLookup = validators.validators.deleteAndGetDeleted(msg.validator);
                assert(validatorLookup.isFound, ErrorsPool.ValidatorNotFound);
                var validatorData = validatorLookup.loadValue();
                if (validatorData.usageState > 0) {
                    // Ban it from new stakes, but keeping the record till return
                    validatorData.isBanned = true;
                    validators.validators.set(msg.validator, validatorData);
                }
                storage.validators = validators.toCell();
                storage.save();

                refundError(
                    sender,
                    {
                        op: opcode<RemoveValidator>(),
                        errorCode: 0,
                        queryId: msg.queryId,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            } catch (e) {
                refundError(
                    sender,
                    {
                        op: opcode<RemoveValidator>(),
                        errorCode: e,
                        queryId: msg.queryId,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            }
        }
        OwnerWithdrawal => {
            try {
                val validators = lazy storage.validators.load();
                assert(sender == storage.owner, ErrorsPool.NotOwner);

                // pending withdrawals are alredy part of nominatorsAmount
                val pendingAmounts = storage.pendingDeposits;

                val availableBalance = contract.getOriginalBalance() - value - pendingAmounts -
                POOL_MIN_STORAGE;

                val totalBalance = availableBalance + validators.stakeUsed;

                val ownerShare = totalBalance - storage.nominatorsAmount -
                getMaxPunishmentInt(validators.minTonPerValidator) * validators.activeSlots;
                val withdrawable = min(ownerShare, availableBalance);
                assert(msg.amount <= withdrawable, ErrorsPool.NotEnoughPoolBalance);
                reserveGramsOnBalance(
                    msg.amount,
                    RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT,
                );
                createMessage({
                    bounce: false,
                    dest: sender,
                    value: 0,
                    body: OwnerWithdrawalSuccess { queryId: msg.queryId },
                }).send(SEND_MODE_CARRY_ALL_BALANCE);
            } catch (e) {
                refundError(
                    sender,
                    {
                        op: opcode<OwnerWithdrawal>(),
                        queryId: msg.queryId,
                        errorCode: e,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
            }
        }
        UpdateLimits => {
            try {
                var storage = lazy Storage.load();
                var validators = lazy storage.validators.load();
                assert(sender == storage.owner, ErrorsPool.NotOwner);

                match (msg.limit) {
                    GlobalValidatorsLimit => {
                        validators.assertStakingLimit(
                            msg.limit.minTonPerValidator,
                            msg.limit.maxTonPerValidator,
                        );
                        validators.minTonPerValidator = msg.limit.minTonPerValidator;
                        validators.maxTonPerValidator = msg.limit.maxTonPerValidator;
                        validators.maxRefundAmount = msg.limit.maxRefund;
                    }
                    ValidatorSpecific => {
                        var validatorData = validators.getValidatorByAddress(
                            msg.limit.validator,
                            ErrorsPool.ValidatorNotFound,
                        )!;
                        validators.assertValidatorLimit(msg.limit.limit);
                        validatorData.data.limit = msg.limit.limit;
                        validators.updateValidatorByAddress(msg.limit.validator, validatorData);
                    }
                    GlobalNominatorsLimit => {
                        var nominators = lazy storage.nominators.load();
                        storage.maxNominators = msg.limit.maxNm;
                        nominators.minStake = msg.limit.minStake;
                        storage.nominators = nominators.toCell();
                    }
                }
                storage.validators = validators.toCell();
                storage.save();
                refundError(
                    sender,
                    {
                        op: opcode<UpdateLimits>(),
                        errorCode: 0,
                        queryId: msg.queryId,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            } catch (e) {
                refundError(
                    sender,
                    {
                        op: opcode<UpdateLimits>(),
                        errorCode: e,
                        queryId: msg.queryId,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            }
        }
        else => {
            handled = false;
        }
    }
    return handled;
}
