import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const bridge = fs.readFileSync(new URL('../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', import.meta.url), 'utf8');
const source = bridge.match(/kTatwoTypeIntoNode\[\] = R"TATWOJS\(([\s\S]*?)\)TATWOJS";/)?.[1];
assert.ok(source, 'extract the exact production typing function, not a rewritten test version');
function fixture(overrides = {}) {
  const document = {};
  const expectedURL = 'https://example.invalid/fixture';
  const window = {}; window.top = window;
  class Node {
    get isConnected() { return this.connected !== false; }
    get ownerDocument() { return document; }
  }
  class Form extends Node {
    get action() { return expectedURL; }
    get method() { return 'get'; }
    get target() { return ''; }
    get enctype() { return 'application/x-www-form-urlencoded'; }
    requestSubmit() { this.onSubmit?.(); }
  }
  let reads = 0;
  class Input {
    constructor() { Object.assign(this, {tagName:'INPUT', type:'text', isConnected:true, ownerDocument:document, events:[], _value:'old'}); }
    set value(value) { this._value = value; }
    get value() { reads++; throw new Error('must not read form values'); }
    getAttribute(name) { return this.attributes?.[name] ?? null; }
    focus() { this.onFocus?.(); }
    dispatchEvent(event) { this.events.push(event.type); this.onEvent?.(event); return true; }
  }
  class Textarea extends Input {
    constructor() { super(); this.tagName = 'TEXTAREA'; }
    set value(value) { this._value = value; }
    get value() { reads++; throw new Error('must not read form values'); }
  }
  const production = vm.runInNewContext('('+source+')', {document, window, location:{href:expectedURL},
    Node, HTMLFormElement:Form, HTMLElement:Input, EventTarget:Input,
    HTMLInputElement:Input, HTMLTextAreaElement:Textarea, Event:class {constructor(type){this.type=type;}}});
  // Supply the observed document URL exactly as the production native caller does.
  const fn = function(text, submit) { return production.call(this, text, submit, expectedURL); };
  const field = Object.assign(overrides.tagName === 'TEXTAREA' ? new Textarea() : new Input(), overrides);
  return {field, fn, document, Form, reads:()=>reads};
}
test('exact native function replaces a later field without reading its value', () => {
  const f = fixture(); assert.equal(f.fn.call(f.field,'hello',false),true);
  assert.equal(f.field._value,'hello'); assert.deepEqual(f.field.events,['input','change']); assert.equal(f.reads(),0);
});
test('Unicode, emoji, quotes and code-like input are data, never source', () => {
  const f = fixture(); const text = '繁體中文 🐱 "\\ \n ); globalThis.pwned=true; //';
  assert.equal(f.fn.call(f.field,text,false),true); assert.equal(f.field._value,text); assert.equal(globalThis.pwned,undefined);
});
test('textarea and empty replacement remain supported', () => {
  const f = fixture({tagName:'TEXTAREA'}); assert.equal(f.fn.call(f.field,'',false),true); assert.equal(f.field._value,'');
});
for (const type of ['password','hidden','file','checkbox','radio']) {
  test('refuses '+type+' controls', () => {
    const f = fixture({type}); assert.equal(f.fn.call(f.field,'must-not-write',false),false); assert.equal(f.field._value,'old');
  });
}
for (const overrides of [{disabled:true},{readOnly:true},{isConnected:false},{ownerDocument:{}},{autocomplete:'one-time-code'},{name:'auth_token'},{attributes:{'aria-label':'Credit card number'}}]) {
  test('refuses unsafe or unavailable field '+JSON.stringify(overrides), () => {
    const f = fixture(overrides); assert.equal(f.fn.call(f.field,'must-not-write',false),false); assert.equal(f.field._value,'old');
  });
}
test('focus handler cannot change field to password then receive text', () => {
  const f=fixture(); f.field.onFocus=()=>{f.field.type='password';}; assert.equal(f.fn.call(f.field,'must-not-write',false),false); assert.equal(f.field._value,'old');
});
test('detached target during focus does not receive text', () => {
  const f=fixture(); f.field.onFocus=()=>{f.field.isConnected=false;}; assert.equal(f.fn.call(f.field,'must-not-write',false),false); assert.equal(f.field._value,'old');
});
test('focus redirection cannot send text into another field or App', () => {
  const f=fixture(); const other={value:'untouched'}; f.field.onFocus=()=>{f.document.activeElement=other;};
  assert.equal(f.fn.call(f.field,'intended',false),true); assert.equal(f.field._value,'intended'); assert.equal(other.value,'untouched');
});
test('form submission is explicit and invoked once', () => {
  const f=fixture(); let submitted=0; f.field.form=new f.Form(); f.field.form.onSubmit=()=>{submitted++;};
  f.fn.call(f.field,'one',false); assert.equal(submitted,0); f.fn.call(f.field,'two',true); assert.equal(submitted,1);
});
test('removed field after input events cannot submit its old form', () => {
  const f=fixture(); let submitted=0; f.field.form=new f.Form(); f.field.form.onSubmit=()=>{submitted++;};
  f.field.onEvent=()=>{f.field.isConnected=false;}; assert.equal(f.fn.call(f.field,'text',true),false); assert.equal(submitted,0); // mutation during input invalidates submission
});
test('runtime failures are not converted into successful typing', () => {
  const f=fixture(); f.field.onFocus=()=>{throw new Error('fixture listener');}; assert.throws(()=>f.fn.call(f.field,'text',false),/fixture listener/);
});
test('production uses node-bound data arguments and no global event injection', () => {
  const swift=fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift',import.meta.url),'utf8');
  assert.doesNotMatch(swift,/CGEvent|cghidEventTap|NSApp\.postEvent|TatwoCEFRuntime\.captureActiveVisibleSnapshot/);
  assert.match(bridge,/SetString\("functionDeclaration", type_kind_ == NodeInputKind::select \? kTatwoSelectNode : kTatwoTypeIntoNode\)/);
  assert.match(bridge,/SetString\("value", ToCefString\(type_text_\)\)/);
});


test('production typing refuses a mismatched observed URL and an embedded frame', () => {
  for (const wrongFrame of [false, true]) {
    const f = fixture(), window = {}; window.top = wrongFrame ? {} : window;
    const fn = vm.runInNewContext('('+source+')', { window, location: {href:'https://example.invalid/new'} });
    assert.equal(fn.call(f.field, 'never write', false, 'https://example.invalid/observed'), false);
    assert.equal(f.field._value, 'old');
  }
});
