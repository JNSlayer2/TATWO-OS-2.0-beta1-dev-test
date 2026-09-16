import test from 'node:test';
import { runOmniboxNativeChecks } from './helpers/omnibox-native-checks.mjs';

// W67 replaced the always-visible TextField with a click-open editor. Keep the
// existing opt-in entrypoint, but exercise both states and all three widths via
// the real production toolbar instead of expecting a field in the idle row.
test('actual browser navigation row renders without squeezing out the address field', {
  skip: process.env.TATWO_BROWSER_ADDRESS_NATIVE !== '1'
    ? 'Lead compiler approval required (TATWO_BROWSER_ADDRESS_NATIVE=1)' : false,
  timeout: 180_000,
}, runOmniboxNativeChecks);
