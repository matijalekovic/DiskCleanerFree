// Number and size formatting. Windows reports sizes in binary units (1 KB = 1024 bytes), macOS in decimal.
'use strict';

const Format = (() => {
  let base = 1000;
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const counter = new Intl.NumberFormat();

  function setBinary(binary) { base = binary ? 1024 : 1000; }

  function split(value, fixedDecimals) {
    let amount = Math.max(0, value);
    let index = 0;
    while (amount >= base && index < units.length - 1) { amount /= base; index++; }
    const decimals = index === 0 ? 0 : fixedDecimals ?? (amount >= 100 ? 1 : 2);
    const number = new Intl.NumberFormat(undefined, {
      minimumFractionDigits: fixedDecimals !== undefined && index > 0 ? decimals : 0,
      maximumFractionDigits: decimals,
    }).format(amount);
    return { number, unit: units[index] };
  }

  return {
    setBinary,
    bytes: (value) => { const { number, unit } = split(value); return `${number} ${unit}`; },
    /** Fixed single decimal, so live counters don't change width every tick. */
    steady: (value) => split(value, 1),
    count: (value) => counter.format(value),
    percent: (part, whole) => {
      if (!whole) return '';
      const value = part / whole;
      if (value < 0.001) return '<0.1%';
      return new Intl.NumberFormat(undefined, { style: 'percent', maximumFractionDigits: value < 0.1 ? 1 : 0 }).format(value);
    },
    duration: (seconds) => {
      const s = Math.floor(seconds);
      return s >= 60 ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` : `${s}s`;
    },
  };
})();
