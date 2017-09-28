#!/usr/bin/env node

function Colored(s, color) {
    this.s = s;

    this.toString = function () {
        return '\x1B[' + color + 'm' + this.s + '\x1B[0m';
    };
    this.valueOf = this.toString;
    this.concat = function (a) {
        this.s = a.reduce(function (acc, val) {
            return acc + (val instanceof Colored ? val.s : val);
        }, '');
        return this;
    };
}

Colored.prototype = Object.create(String.prototype, {
  constructor: { value: Colored },
  length: {get: function () {
      return this.s.length;
  }}
});

function red(s,fc) {
    return (fc || process.stdout.isTTY ? new Colored(s, 31) : s);
}

function yellow(s,fc) {
    return (fc || process.stdout.isTTY ? new Colored(s, 93) : s);
}

function grey(s,fc) {
    return (fc || process.stdout.isTTY ? new Colored(s, 90) : s);
}

function green(s,fc) {
    return (fc || process.stdout.isTTY ? new Colored(s, 32) : s);
}

function orange(s,fc) {
    return (fc || process.stdout.isTTY ? new Colored(s, 33) : s);
}

module.exports = {
    'green':green,
    'yellow':yellow,
    'orange':orange,
    'red':red,
    'grey':grey
}
