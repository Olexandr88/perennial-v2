import { smock } from '@defi-wonderland/smock'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect, use } from 'chai'
import HRE from 'hardhat'

import {
  CheckpointLib,
  CheckpointLib__factory,
  CheckpointStorageLib,
  CheckpointStorageLib__factory,
  CheckpointTester,
  CheckpointTester__factory,
} from '../../../types/generated'
import { BigNumber } from 'ethers'
import { CheckpointStruct, PositionStruct, VersionStruct } from '../../../types/generated/contracts/Market'
import {
  DEFAULT_ORDER,
  DEFAULT_CHECKPOINT,
  DEFAULT_VERSION,
  DEFAULT_POSITION,
  DEFAULT_INTENT,
  parse6decimal,
} from '../../../../common/testutil/types'

const { ethers } = HRE
use(smock.matchers)

describe('Checkpoint', () => {
  let owner: SignerWithAddress
  let checkpointLib: CheckpointLib
  let checkpointStorageLib: CheckpointStorageLib
  let checkpoint: CheckpointTester

  const VALID_CHECKPOINT: CheckpointStruct = {
    tradeFee: 3,
    settlementFee: 4,
    transfer: 6,
    collateral: 5,
  }

  beforeEach(async () => {
    ;[owner] = await ethers.getSigners()

    checkpointLib = await new CheckpointLib__factory(owner).deploy()
    checkpointStorageLib = await new CheckpointStorageLib__factory(owner).deploy()
    checkpoint = await new CheckpointTester__factory(
      {
        'contracts/libs/CheckpointLib.sol:CheckpointLib': checkpointLib.address,
        'contracts/types/Checkpoint.sol:CheckpointStorageLib': checkpointStorageLib.address,
      },
      owner,
    ).deploy()
  })

  describe('#store', () => {
    it('stores a new value', async () => {
      await checkpoint.store(VALID_CHECKPOINT)

      const value = await checkpoint.read()
      expect(value.tradeFee).to.equal(3)
      expect(value.settlementFee).to.equal(4)
      expect(value.transfer).to.equal(6)
      expect(value.collateral).to.equal(5)
    })

    describe('.tradeFee', async () => {
      const STORAGE_SIZE = 47
      it('saves if in range (above)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          tradeFee: BigNumber.from(2).pow(STORAGE_SIZE).sub(1),
        })
        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).sub(1))
      })

      it('saves if in range (below)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          tradeFee: BigNumber.from(2).pow(STORAGE_SIZE).mul(-1),
        })
        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).mul(-1))
      })

      it('reverts if tradeFee out of range (above)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            tradeFee: BigNumber.from(2).pow(STORAGE_SIZE),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })

      it('reverts if tradeFee out of range (below)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            tradeFee: BigNumber.from(2).pow(STORAGE_SIZE).add(1).mul(-1),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })
    })

    describe('.settlementFee', async () => {
      const STORAGE_SIZE = 48
      it('saves if in range', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          settlementFee: BigNumber.from(2).pow(STORAGE_SIZE).sub(1),
        })
        const value = await checkpoint.read()
        expect(value.settlementFee).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).sub(1))
      })

      it('reverts if settlementFee out of range)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            settlementFee: BigNumber.from(2).pow(STORAGE_SIZE),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })
    })

    describe('.transfer', async () => {
      const STORAGE_SIZE = 63
      it('saves if in range (above)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          transfer: BigNumber.from(2).pow(STORAGE_SIZE).sub(1),
        })
        const value = await checkpoint.read()
        expect(value.transfer).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).sub(1))
      })

      it('saves if in range (below)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          transfer: BigNumber.from(2).pow(STORAGE_SIZE).mul(-1),
        })
        const value = await checkpoint.read()
        expect(value.transfer).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).mul(-1))
      })

      it('reverts if delta out of range (above)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            transfer: BigNumber.from(2).pow(STORAGE_SIZE),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })

      it('reverts if delta out of range (below)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            transfer: BigNumber.from(2).pow(STORAGE_SIZE).add(1).mul(-1),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })
    })

    describe('.collateral', async () => {
      const STORAGE_SIZE = 63
      it('saves if in range (above)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          collateral: BigNumber.from(2).pow(STORAGE_SIZE).sub(1),
        })
        const value = await checkpoint.read()
        expect(value.collateral).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).sub(1))
      })

      it('saves if in range (below)', async () => {
        await checkpoint.store({
          ...VALID_CHECKPOINT,
          collateral: BigNumber.from(2).pow(STORAGE_SIZE).mul(-1),
        })
        const value = await checkpoint.read()
        expect(value.collateral).to.equal(BigNumber.from(2).pow(STORAGE_SIZE).mul(-1))
      })

      it('reverts if collateral out of range (above)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            collateral: BigNumber.from(2).pow(STORAGE_SIZE),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })

      it('reverts if collateral out of range (below)', async () => {
        await expect(
          checkpoint.store({
            ...VALID_CHECKPOINT,
            collateral: BigNumber.from(2).pow(STORAGE_SIZE).add(1).mul(-1),
          }),
        ).to.be.revertedWithCustomError(checkpointStorageLib, 'CheckpointStorageInvalidError')
      })
    })
  })

  describe('#accumulate', () => {
    const FROM_POSITION: PositionStruct = {
      timestamp: 0, // unused
      maker: parse6decimal('987'),
      long: parse6decimal('654'),
      short: parse6decimal('321'),
    }

    const TO_POSITION: PositionStruct = {
      timestamp: 0, // unused
      maker: 0,
      long: 0,
      short: 0,
    }

    const FROM_VERSION: VersionStruct = {
      valid: true,
      price: parse6decimal('123'),
      makerValue: { _value: parse6decimal('100') },
      longValue: { _value: parse6decimal('200') },
      shortValue: { _value: parse6decimal('300') },
      makerFee: { _value: parse6decimal('1400') },
      takerFee: { _value: parse6decimal('1600') },
      makerOffset: { _value: parse6decimal('400') },
      takerPosOffset: { _value: parse6decimal('600') },
      takerNegOffset: { _value: parse6decimal('700') },
      settlementFee: { _value: parse6decimal('800') },
      liquidationFee: { _value: parse6decimal('900') },
    }

    const TO_VERSION: VersionStruct = {
      valid: true,
      price: parse6decimal('123'),
      makerValue: { _value: parse6decimal('1000') },
      longValue: { _value: parse6decimal('2000') },
      shortValue: { _value: parse6decimal('3000') },
      makerFee: { _value: parse6decimal('14000') },
      takerFee: { _value: parse6decimal('16000') },
      makerOffset: { _value: parse6decimal('4000') },
      takerPosOffset: { _value: parse6decimal('6000') },
      takerNegOffset: { _value: parse6decimal('7000') },
      settlementFee: { _value: parse6decimal('8000') },
      liquidationFee: { _value: parse6decimal('9000') },
    }

    context('zero initial values', () => {
      beforeEach(async () => {
        await checkpoint.store({
          ...DEFAULT_CHECKPOINT,
        })
      })

      it('accumulates transfer', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, collateral: parse6decimal('123') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, collateral: parse6decimal('123') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION },
        )

        const value = await checkpoint.read()
        expect(value.transfer).to.equal(parse6decimal('123'))
      })

      it('accumulates price override pnl (long)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10'), longNeg: parse6decimal('5') },
          {
            ...DEFAULT_INTENT,
            takerPos: parse6decimal('5'),
            takerNeg: parse6decimal('2'),
            notional: parse6decimal('300'),
          },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, price: parse6decimal('123') },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10'), longNeg: parse6decimal('5') },
          {
            ...DEFAULT_INTENT,
            takerPos: parse6decimal('5'),
            takerNeg: parse6decimal('2'),
            notional: parse6decimal('300'),
          },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, price: parse6decimal('123') },
        )
        expect(result.priceOverride).to.equal(parse6decimal('69')) // open 3 long @ 100 w/ 123 price

        const value = await checkpoint.read()
        expect(value.collateral).to.equal(parse6decimal('69'))
      })

      it('accumulates price override pnl (short)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, shortPos: parse6decimal('10'), shortNeg: parse6decimal('5') },
          {
            ...DEFAULT_INTENT,
            takerNeg: parse6decimal('5'),
            takerPos: parse6decimal('2'),
            notional: parse6decimal('-300'),
          },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, price: parse6decimal('123') },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, shortPos: parse6decimal('10'), shortNeg: parse6decimal('5') },
          {
            ...DEFAULT_INTENT,
            takerNeg: parse6decimal('5'),
            takerPos: parse6decimal('2'),
            notional: parse6decimal('-300'),
          },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, price: parse6decimal('123') },
        )
        expect(result.priceOverride).to.equal(parse6decimal('-69')) // open 3 short @ 100 w/ 123 price

        const value = await checkpoint.read()
        expect(value.collateral).to.equal(parse6decimal('-69'))
      })

      it('accumulates pnl (maker)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, maker: parse6decimal('10') },
          { ...DEFAULT_VERSION, makerValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, makerValue: { _value: parse6decimal('200') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, maker: parse6decimal('10') },
          { ...DEFAULT_VERSION, makerValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, makerValue: { _value: parse6decimal('200') } },
        )
        expect(result.collateral).to.equal(parse6decimal('1000'))

        const value = await checkpoint.read()
        expect(value.collateral).to.equal(parse6decimal('1000'))
      })

      it('accumulates pnl (long)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, long: parse6decimal('10') },
          { ...DEFAULT_VERSION, longValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, longValue: { _value: parse6decimal('200') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, long: parse6decimal('10') },
          { ...DEFAULT_VERSION, longValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, longValue: { _value: parse6decimal('200') } },
        )
        expect(result.collateral).to.equal(parse6decimal('1000'))

        const value = await checkpoint.read()
        expect(value.collateral).to.equal(parse6decimal('1000'))
      })

      it('accumulates pnl (short)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, short: parse6decimal('10') },
          { ...DEFAULT_VERSION, shortValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, shortValue: { _value: parse6decimal('200') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION, short: parse6decimal('10') },
          { ...DEFAULT_VERSION, shortValue: { _value: parse6decimal('100') } },
          { ...DEFAULT_VERSION, shortValue: { _value: parse6decimal('200') } },
        )
        expect(result.collateral).to.equal(parse6decimal('1000'))

        const value = await checkpoint.read()
        expect(value.collateral).to.equal(parse6decimal('1000'))
      })

      it('accumulates fees (maker)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, makerPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, makerFee: { _value: parse6decimal('-2') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, makerPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, makerFee: { _value: parse6decimal('-2') } },
        )
        expect(result.tradeFee).to.equal(parse6decimal('20'))

        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(parse6decimal('20'))
      })

      it('accumulates fees (taker)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerFee: { _value: parse6decimal('-2') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerFee: { _value: parse6decimal('-2') } },
        )
        expect(result.tradeFee).to.equal(parse6decimal('20'))

        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(parse6decimal('20'))
      })

      it('accumulates fees (maker offset)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, makerPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, makerOffset: { _value: parse6decimal('-2') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, makerPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, makerOffset: { _value: parse6decimal('-2') } },
        )
        expect(result.offset).to.equal(parse6decimal('20'))

        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(parse6decimal('20'))
      })

      it('accumulates fees (taker pos offset)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerPosOffset: { _value: parse6decimal('-2') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, longPos: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerPosOffset: { _value: parse6decimal('-2') } },
        )
        expect(result.offset).to.equal(parse6decimal('20'))

        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(parse6decimal('20'))
      })

      it('accumulates fees (taker neg offset)', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, longNeg: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerNegOffset: { _value: parse6decimal('-2') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, longNeg: parse6decimal('10') },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, takerNegOffset: { _value: parse6decimal('-2') } },
        )
        expect(result.offset).to.equal(parse6decimal('20'))

        const value = await checkpoint.read()
        expect(value.tradeFee).to.equal(parse6decimal('20'))
      })

      it('accumulates settlement fee', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, orders: 2 },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, settlementFee: { _value: parse6decimal('-4') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, orders: 2 },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, settlementFee: { _value: parse6decimal('-4') } },
        )
        expect(result.settlementFee).to.equal(parse6decimal('8'))

        const value = await checkpoint.read()
        expect(value.settlementFee).to.equal(parse6decimal('8'))
      })

      it('accumulates liquidation fee', async () => {
        const result = await checkpoint.callStatic.accumulate(
          { ...DEFAULT_ORDER, protection: 1 },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, liquidationFee: { _value: parse6decimal('-4') } },
        )
        await checkpoint.accumulate(
          { ...DEFAULT_ORDER, protection: 1 },
          { ...DEFAULT_INTENT },
          { ...DEFAULT_POSITION },
          { ...DEFAULT_VERSION },
          { ...DEFAULT_VERSION, liquidationFee: { _value: parse6decimal('-4') } },
        )
        expect(result.liquidationFee).to.equal(parse6decimal('4'))

        const value = await checkpoint.read()
        expect(value.settlementFee).to.equal(parse6decimal('4'))
      })
    })
  })
})
