import "@contracts/config"
import "@contracts/utils"
import "@gen/Proxy.code"
import "errors"
import "fees"
import "messages"
import "types"

fun ValidatorsData.assertValidatorLimit(self, limit: ValidatorLimit) {
    match (limit) {
        ValidatorLimitTon => {
            assert(limit.maxTon <=
            self.maxTonPerValidator, ErrorsPool.IndividualLimitIsAboveGlobal);
            assert(limit.maxTon >=
            self.minTonPerValidator, ErrorsPool.IndividualLimitIsBelowGlobal);
        }
        ValidatorLimitShare => {
            assert(limit.maxShare <= SHARE_BASE, ErrorsPool.InvalidValidatorShare);
        }
    }
}

fun assertStakingLimit(minTonPerValidator: coins, maxTonPerValidator: coins) {
    val networkLimits = lazy StakingLimits.load();
    assert(maxTonPerValidator > minTonPerValidator, ErrorsPool.InvalidMaxMin);
    assert(minTonPerValidator >= networkLimits.minStake, ErrorsPool.MinStakeBelowNetworkLimit);
    assert(maxTonPerValidator <= networkLimits.maxStake, ErrorsPool.MaxStakeAboveNetworkLimit);
}

fun ValidatorsData.coverUsageByAddress(
    mutate self,
    address: address,
    amount: int,
    curFirst: bool,
): (TonUsage?, uint64, bool) {
    val (firstRound, nextRound) = curFirst
        ? (self.curRound, self.prevRound)
        : (self.prevRound, self.curRound);
    var round = firstRound.load();
    val (wc, addrHash) = address.getWorkchainAndHash();
    // Do nothing for basechain addresses
    // Bit of a hack, but it's okay?
    if (wc == BASECHAIN) {
        return (null, round.roundIndex, round.users.isEmpty());
    }
    var lookup = round.coverUsage(addrHash, amount);

    if (lookup != null) {
        val roundCell = round.toCell();
        if (curFirst) {
            self.curRound = roundCell;
        } else {
            self.prevRound = roundCell;
        }
        return (lookup, round.roundIndex, round.users.isEmpty());
    }

    round = nextRound.load();
    lookup = round.coverUsage(addrHash, amount);

    if (lookup != null) {
        val roundCell = round.toCell();
        if (curFirst) {
            self.prevRound = roundCell;
        } else {
            self.curRound = roundCell;
        }
    }

    return (lookup, round.roundIndex, round.users.isEmpty());
}

fun ValidatorsData.getValidatorByAddress(
    self,
    address: address,
    throwIfNotFound: int?,
): ValidatorLookup? {
    if (address == self.mainValidatorAddress) {
        val mainData = lazy self.mainValidatorData.load();
        return { isMain: true, data: mainData };
    }

    val valLookup = self.validators.get(address);
    if (valLookup.isFound) {
        return { isMain: false, data: valLookup.loadValue() };
    }

    assert(throwIfNotFound == null, throwIfNotFound);

    return null;
}

fun ValidatorsData.updateValidatorByAddress(
    mutate self,
    address: address,
    validator: ValidatorLookup,
) {
    if (validator.isMain) {
        self.mainValidatorData = validator.data.toCell();
    } else {
        self.validators.set(address, validator.data);
    }
}

fun ValidatorsData.getUsageRecord(
    self,
    addrHash: uint256,
    usageMask: uint2,
    throwIfNotFound: int?,
): UsageLookup? {
    var round = self.prevRound.load();
    var bitIdx = toBitIndex(round.roundIndex);
    if ((usageMask & bitIdx) != 0) {
        var lookup = round.users.get(addrHash);
        if (lookup.isFound) {
            return {
                isCurrentRound: false,
                data: lookup.loadValue(),
                round,
            };
        }
    }
    round = self.curRound.load();
    bitIdx = toBitIndex(round.roundIndex);

    if ((usageMask & bitIdx) != 0) {
        val lookup = round.users.get(addrHash);
        if (lookup.isFound) {
            return {
                isCurrentRound: true,
                data: lookup.loadValue(),
                round,
            };
        }
    }
    assert(throwIfNotFound == null, throwIfNotFound);

    return null;
}

fun ValidatorsData.rotateRound(
    mutate self,
    address: address,
    roundIndex: int,
    inValue: coins = 0,
): RotationStatus {
    val curVset = getCurVset();

    var curRound: RoundData? = null;
    var rotatedInfo: RoundInfo? = null;
    var prevRound: RoundData;
    var updatedCur = false;
    var updatedPrev = false;
    var closed = false;
    val isMain = address == self.mainValidatorAddress;

    prevRound = self.prevRound.load();
    val truncHash = curVset.vsetHash >> 128;

    val setRotated = truncHash != self.vsetHash;

    if (setRotated) {
        if (!prevRound.users.isEmpty()) {
            closed = true;
        } else {
            self.vsetHash = truncHash;

            rotatedInfo = RoundInfo {
                used: prevRound.used,
                returned: prevRound.returned,
                roundIndex: prevRound.roundIndex,
            };
            // self.mainValidatorData = mainData.toCell();
            self.prevRound = self.curRound;
            // Reload the prev round only here
            prevRound = self.curRound.load();
            roundIndex += 1;
            curRound = RoundData { roundIndex };
            self.curRound = curRound.toCell();
        }
    }

    val bitIdx = toBitIndex(roundIndex);
    if (isMain) {
        var mainValidator = lazy self.mainValidatorData.load();
        mainValidator.refundAmount += inValue;
        if (mainValidator.usageState > 0) {
            if (curRound == null) {
                curRound = self.curRound.load();
            }

            val (updCur, updPrev) = mainValidator.rotateVset(
                bitIdx,
                curVset.vsetHash,
                mutate curRound,
                mutate prevRound,
            );
            updatedCur = updatedCur || updCur;
            updatedPrev = updatedPrev || updPrev;
            self.mainValidatorData = mainValidator.toCell();
        }
    } else {
        val myValidator = self.validators.get(address);
        if (myValidator.isFound) {
            var valData = myValidator.loadValue();

            if (valData.usageState > 0) {
                if (curRound == null) {
                    curRound = self.curRound.load();
                }

                val (updCur, updPrev) = valData.rotateVset(
                    bitIdx,
                    curVset.vsetHash,
                    mutate curRound,
                    mutate prevRound,
                );
                updatedCur = updatedCur || updCur;
                updatedPrev = updatedPrev || updPrev;
                if (inValue > 0) {
                    valData.refundAmount += inValue;
                    self.validators.set(address, valData);
                }
            }
        } else {
            // Good Samaritan willing to spend TON to rotate for everybody
            var curReccord = self.validators.findFirst();
            if (curRound == null) {
                curRound = self.curRound.load();
            }

            var mainValidator = lazy self.mainValidatorData.load();
            mainValidator.rotateVset(bitIdx, curVset.vsetHash, mutate curRound, mutate prevRound);
            while (curReccord.isFound) {
                var valData = curReccord.loadValue();

                val (updCur, updPrev) = valData.rotateVset(
                    bitIdx,
                    curVset.vsetHash,
                    mutate curRound,
                    mutate prevRound,
                );
                updatedCur = updatedCur || updCur;
                updatedPrev = updatedPrev || updPrev;

                curReccord = self.validators.iterateNext(curReccord);
            }
        }
    }

    if (updatedCur) {
        self.curRound = curRound!.toCell();
    }
    if (updatedPrev) {
        self.prevRound = prevRound!.toCell();
    }

    return {
        roundRotated: setRotated && (!closed),
        roundIsClosed: closed,
        prevRoundInfo: rotatedInfo,
    };
}

fun RotationData.checkRecoverRequirements(self, heldFor: int): int {
    assert(self.rotationCount >= 2, ErrorsPool.RoundTooEarly);
    // For over 2 rounds, timestamp is irrelevant.
    var expTimestamp = 0;
    if (self.rotationCount == 2) {
        expTimestamp = self.rotationTime + heldFor + 60;
        assert(blockchain.now() > expTimestamp, ErrorsPool.RecoveryTimeTooEarly);
    }
    return expTimestamp;
}

fun RoundData.rotateRoundRecords(mutate self, proxyHash: uint256, curVset: int): bool {
    val usageLookup = self.users.get(proxyHash);
    if (usageLookup.isFound) {
        var usageData = usageLookup.loadValue();
        if (usageData.rotation.rotateVset(curVset)) {
            self.users.set(proxyHash, usageData);
            return true;
        }
    }
    return false;
}

fun RoundData.coverUsage(mutate self, addressHash: uint256, amount: int): TonUsage? {
    val lookup = self.users.deleteAndGetDeleted(addressHash);
    if (lookup.isFound) {
        self.returned += amount;
        return lookup.loadValue();
    }
    return null;
}

fun Validator.deployProxy(
    mutate self,
    address: address,
    response: address,
    budget: int,
    queryId: int,
) {
    var roundAllowence = self.roundParity as int;
    var bitPosition = 1;
    val deployCost = PROXY_MIN_STORAGE + PROXY_INIT_VALUE;

    while (roundAllowence != 0) {
        if (roundAllowence % 2 != 0) {
            budget -= deployCost;
            assert(budget > 0, ErrorsPool.NotEnoughGas);
            val parity = bitPosition % 2 > 0;
            val proxyState = getProxyState(address, parity);
            val proxyAddrHash = proxyState.calculateAddress().getHash();
            if (parity) {
                self.oddProxy = proxyAddrHash;
            } else {
                self.evenProxy = proxyAddrHash;
            }

            val proxyInit = createMessage({
                bounce: false,
                dest: proxyState,
                value: deployCost,
                body: InitProxy { queryId, response },
            });
            proxyInit.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        bitPosition += 1;
        roundAllowence >>= 1;
    }
}

fun Validator.rotateVset(
    mutate self,
    bitIdx: int,
    curVsetHash: int,
    mutate curRound: RoundData,
    mutate prevRound: RoundData,
): (bool, bool) {
    var updatedCurrent: bool = false;
    var updatedPrev: bool = false;
    if ((bitIdx & self.usageState) != 0) {
        val proxyAddr = self.getProxyByParity(bitIdx);
        updatedCurrent = curRound.rotateRoundRecords(proxyAddr, curVsetHash);
    }
    bitIdx = (bitIdx << 1) % 3;
    if ((bitIdx & self.usageState) != 0) {
        val proxyAddr = self.getProxyByParity(bitIdx);
        updatedPrev = prevRound.rotateRoundRecords(proxyAddr, curVsetHash);
    }
    return (updatedCurrent, updatedPrev);
}

fun RotationData.rotateVset(mutate self, newSetHash: int): bool {
    val hasRotated = self.vsetHash != newSetHash;

    if (hasRotated) {
        self.vsetHash = newSetHash;
        self.rotationTime = blockchain.now();
        self.rotationCount = (self.rotationCount + 1) % 0xff;
    }
    return hasRotated;
}

fun getCurVset(): CurrentVset {
    var vsetCell = blockchain.configParam(34)!;
    val curVset = CurrentVsetParsed.fromCell(vsetCell, { assertEndAfterReading: false });

    return {
        utimeSince: curVset.utimeSince,
        utimeUntil: curVset.utimeUntil,
        vsetHash: vsetCell.hash(),
    };
}

fun Validator.getProxyByParity(self, bitIdx: int): uint256 {
    if ((bitIdx & 1) == 0) {
        return self.evenProxy!;
    }
    return self.oddProxy!;
}

fun Validator.getProxyAddressByParity(self, bitIdx: int): address {
    return address.fromWorkchainAndHash(MASTERCHAIN, self.getProxyByParity(bitIdx));
}

fun Validator.allUsageRecords(
    self,
    bitIdx: int,
    curRound: RoundData,
    prevRound: RoundData,
): ValidatorUsageRecords {
    var curUsage: ValidatorUsageStats? = null;
    var prevUsage: ValidatorUsageStats? = null;

    if ((bitIdx & self.usageState) != 0) {
        val proxyAddrHash = self.getProxyByParity(bitIdx);
        curUsage = ValidatorUsageStats {
            proxy: proxyAddrHash,
            usage: curRound.users.mustGet(proxyAddrHash, ErrorsPool.UsageRecordNotFound)!,
        };
    }
    bitIdx = (bitIdx << 1) % 3;
    if ((bitIdx & self.usageState) != 0) {
        val proxyAddrHash = self.getProxyByParity(bitIdx);
        prevUsage = ValidatorUsageStats {
            proxy: proxyAddrHash,
            usage: prevRound.users.mustGet(proxyAddrHash, ErrorsPool.UsageRecordNotFound)!,
        };
    }

    return { curRoundUsage: curUsage, prevRoundUsage: prevUsage };
}

fun getProxyState(validator: address, isOdd: bool): AutoDeployAddress {
    val proxy: AutoDeployAddress = {
        workchain: -1,
        stateInit: {
            data: ProxyStorage {
                validator,
                roundParity: isOdd,
                pool: contract.getAddress(),
            }.toCell(),
            code: proxyCompiledCode(),
        },
    };

    return proxy;
}

fun getProxyAddress(validator: address, isOdd: bool): address {
    return getProxyState(validator, isOdd).calculateAddress();
}

fun getValidatorLimit(limit: ValidatorLimit?, totalBalance: int, maxTonPerValidator: int): int {
    return match (limit) {
        ValidatorLimitTon => min(maxTonPerValidator, limit.maxTon),
        ValidatorLimitShare => min(
            mulDivQuiet(totalBalance, limit.maxShare, SHARE_BASE),
            maxTonPerValidator,
        ),
        null => maxTonPerValidator as int,
    };
}
