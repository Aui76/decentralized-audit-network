/** Uniswap V3 tick / liquidity math (minimal port for demo pool stats). */

const MIN_TICK = -887272;
const MAX_TICK = 887272;

export function getSqrtRatioAtTick(tick) {
  if (tick < MIN_TICK || tick > MAX_TICK) throw new Error("tick out of range");
  const logSqrt = (tick / 2) * Math.log(1.0001) + 96 * Math.log(2);
  return BigInt(Math.floor(Math.exp(logSqrt)));
}

function getAmount0ForLiquidity(sqrtA, sqrtB, liquidity) {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return ((liquidity << 96n) * (sqrtB - sqrtA)) / sqrtB / sqrtA;
}

function getAmount1ForLiquidity(sqrtA, sqrtB, liquidity) {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return (liquidity * (sqrtB - sqrtA)) >> 96n;
}

export function amountsForPosition(liquidity, tickLower, tickUpper, sqrtPriceX96, tick) {
  if (liquidity === 0n) return { amount0: 0n, amount1: 0n };

  const sa = getSqrtRatioAtTick(tickLower);
  const sb = getSqrtRatioAtTick(tickUpper);
  const t = Number(tick);

  if (t < tickLower) {
    return { amount0: getAmount0ForLiquidity(sa, sb, liquidity), amount1: 0n };
  }
  if (t >= tickUpper) {
    return { amount0: 0n, amount1: getAmount1ForLiquidity(sa, sb, liquidity) };
  }
  return {
    amount0: getAmount0ForLiquidity(sqrtPriceX96, sb, liquidity),
    amount1: getAmount1ForLiquidity(sa, sqrtPriceX96, liquidity),
  };
}

export function decodeSignedTick(hexWord) {
  let tick = BigInt(hexWord);
  if (tick >> 255n) tick -= 1n << 256n;
  return tick;
}

export function decodeInt24Word(word) {
  let x = word & 0xffffffn;
  if (x >= 0x800000n) x -= 0x1000000n;
  return Number(x);
}

export function decodePosition(hex) {
  const words = hex.replace(/^0x/, "").match(/.{64}/g) || [];
  return {
    tickLower: decodeInt24Word(BigInt("0x" + words[5])),
    tickUpper: decodeInt24Word(BigInt("0x" + words[6])),
    liquidity: BigInt("0x" + words[7]),
    tokensOwed0: BigInt("0x" + words[10]),
    tokensOwed1: BigInt("0x" + words[11]),
  };
}
