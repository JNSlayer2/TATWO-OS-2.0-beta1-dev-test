import Foundation

/// Runs only in the bridge's isolated WKContentWorld, never the page world.
/// DOM data remains untrusted. Node IDs are host-world WeakMap identities, not
/// page IDs/selectors or attributes a page can assign to a replacement node.
enum BrowserAgentPageScript {
    private static func literal(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [object], options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrowserAgentRequestError("browser_script_encoding_failed")
        }
        return String(text.dropFirst().dropLast())
    }

    private static func setup() -> String {
        """
        const key = '__tatwoComputerUseObservationV1';
        let state = globalThis[key];
        if (!state || state.document !== document) {
          state = {document, seed:'\(UUID().uuidString)', ids:new WeakMap(), next:1, targets:new Map(), used:new Map()};
          globalThis[key] = state;
        }
        const identify = element => {
          if (!state.ids.has(element)) {
            if (state.next > 2147483647) throw new Error('browser_node_identity_exhausted');
            state.ids.set(element, 'wk-' + state.next++);
          }
          return state.ids.get(element);
        };
        const sensitive = element => {
          const hints = [element.type, element.autocomplete, element.name, element.id,
                         element.getAttribute('aria-label'), element.getAttribute('placeholder')].join(' ').toLowerCase();
          return /password|one-time|otp|cc-|credit|card.number|security.code|token/.test(hints);
        };
        // Stable for one loaded document, new after navigation/reload; UUID-shaped for the host check.
        // (The isolated world's state object does not survive between evaluations, so a random seed
        // stored there changed on every snapshot.)
        const documentUUID = () => {
          const hx=(n,w)=>(n>>>0).toString(16).padStart(w,'0').slice(-w);
          let h=5381; for (const ch of location.href) h=((h*33)^ch.charCodeAt(0))>>>0;
          const t=Math.floor(performance.timeOrigin*1000), hi=Math.floor(t/4294967296), lo=t%4294967296;
          return hx(h,8)+'-'+hx(hi>>>16,4)+'-'+hx(hi,4)+'-'+hx(lo>>>16,4)+'-'+hx(lo,8)+hx(h>>>16,4);
        };
        const capture = () => {
          if (!document.body || document.readyState === 'loading') throw new Error('page_not_ready');
          const controls=[], links=[], forms=new Map(), targets=new Map(), blocks=[];
          let scanned=0, truncated=false, subframes=false;
          const rendered = element => {
            let parent=element, depth=0;
            while (parent && depth++ < 64) {
              const style=getComputedStyle(parent);
              if (parent.hidden || style.display === 'none' || style.visibility !== 'visible'
                  || Number(style.opacity) === 0) return false;
              parent=parent.parentElement;
            }
            if (parent) { truncated=true; return false; }
            return true;
          };
          const visibleHit = (element,rect) => {
            if (![rect.x,rect.y,rect.width,rect.height].every(Number.isFinite)
                || rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0
                || rect.left >= innerWidth || rect.top >= innerHeight) return false;
            const x=(Math.max(0,rect.left)+Math.min(innerWidth,rect.right))/2;
            const y=(Math.max(0,rect.top)+Math.min(innerHeight,rect.bottom))/2;
            const hit=document.elementFromPoint(x,y);
            return !!hit && (element === hit || element.contains(hit));
          };
          const candidates=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);
          let element;
          while ((element=candidates.nextNode())) {
            if (++scanned > 6000 || controls.length >= 256) { truncated=true; break; }
            if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') subframes=true;
            if (!element.matches('a,button,input,textarea,select,[contenteditable="true"],[role="button"],[onclick],[draggable="true"],summary,label')) continue;
            const rect = element.getBoundingClientRect();
            if (!rendered(element) || getComputedStyle(element).pointerEvents === 'none'
                || !visibleHit(element,rect)) continue;
            const elementID = identify(element), tag = element.tagName.toLowerCase();
            const type = (element.type || tag).toLowerCase();
            const field = tag === 'textarea' || element.isContentEditable
              || (tag === 'input' && ['text','search','email','url','tel','number','password'].includes(type));
            // Never read an editable field's current value into the snapshot.
            const label = (element.getAttribute('aria-label') || element.getAttribute('placeholder')
              || (field ? '' : element.innerText) || element.title || element.name
              || ((tag === 'input' && ['button','submit','reset'].includes(type)) ? element.value : '') || '')
              .trim().slice(0,160);
            const item = {elementID,kind:tag,type,label,sensitive:sensitive(element),
              disabled:!!element.disabled,readOnly:!!element.readOnly,
              rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}};
            controls.push(item); targets.set(elementID,element);
            if (tag === 'a') links.push(item);
            if (field) {
              const form = element.form, formID = form ? identify(form) : 'wk-unowned-form';
              if (!forms.has(formID)) forms.set(formID,{elementID:formID,
                action:form ? form.action : '',method:form ? form.method : '',fields:[]});
              forms.get(formID).fields.push(item);
            }
          }
          // Bounded visible text traversal, excluding editable field contents.
          // Do not materialize a page-sized body.innerText just to truncate it.
          const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
          let node, visited=0, characters=0;
          while ((node=walker.nextNode())) {
            if (++visited > 4000 || characters >= 50000) { truncated=true; break; }
            const parent=node.parentElement, remaining=50000-characters;
            const text=node.substringData(0,Math.min(node.length,remaining)).trim();
            if (!parent || !text || parent.isContentEditable
                || parent.closest('script,style,noscript,input,textarea,select,[aria-hidden="true"]')
                || !rendered(parent)) continue;
            const range=document.createRange();
            range.setStart(node,0); range.setEnd(node,Math.min(node.length,remaining));
            if (![...range.getClientRects()].some(rect=>visibleHit(parent,rect))) continue;
            blocks.push({text}); characters+=text.length;
            if (node.length > remaining) truncated=true;
          }
          state.targets = targets;
          return {schema:'TatwoWKVisibleSnapshotV1',documentID:documentUUID(),origin:location.origin,
            url:location.href,title:document.title.slice(0,200),
            viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY},
            blocks,controls,links,
            forms:[...forms.values()].sort((a,b)=>a.elementID.localeCompare(b.elementID)),
            riskFlags:[...(truncated ? ['truncated'] : []),
                       ...(subframes ? ['subframes_excluded'] : [])]};
        };
        """
    }

    static func snapshot() -> String {
        "(()=>{\n" + setup() + "\nreturn JSON.stringify(capture());\n})()"
    }

    /// Read-only, isolated-world inspection. Frames and opaque/custom focus fail
    /// closed rather than treating a hidden password input as safe.
    static func safeFocus() -> String {
        "(()=>{\n" + setup() + """
        let el=document.activeElement;
        while (el && el.shadowRoot) el=el.shadowRoot.activeElement;
        return !!el && el.isConnected && !sensitive(el)
          && !el.matches('iframe,frame,object,embed')
          && ['input','textarea','select','button','a','body'].includes(el.localName)
          && !(el.localName==='body' && el.matches(':focus'));
        })()
        """
    }

    static func action(expectedJSON: String, observationID: UUID, kind: String,
                       elementID: String? = nil, text: String = "", submit: Bool = false,
                       dy: Int32 = 0, expiresAtMilliseconds: Double) throws -> String {
        guard ["click", "type", "scroll", "select"].contains(kind), expiresAtMilliseconds.isFinite else {
            throw BrowserAgentRequestError("browser_invalid_action")
        }
        let arguments: [String: Any] = [
            "expected": expectedJSON, "id": observationID.uuidString, "kind": kind,
            "elementID": elementID ?? "", "text": text, "submit": submit,
            "dy": Int(dy), "expires": expiresAtMilliseconds,
        ]
        return "(()=>{\n" + setup() + "\nconst args = " + (try literal(arguments)) + ";\n" + """
        if (Date.now() >= args.expires) throw new Error('browser_action_expired');
        if (JSON.stringify(capture()) !== args.expected) throw new Error('computer_observe_again');
        for (const [id,expiry] of state.used) if (Date.now() >= expiry) state.used.delete(id);
        if (state.used.has(args.id)) throw new Error('browser_action_replayed');
        if (state.used.size >= 128) throw new Error('browser_action_history_busy');
        const target = state.targets.get(args.elementID);
        if (args.kind !== 'scroll' && (!target || !target.isConnected || target.ownerDocument !== document
            || target.disabled || sensitive(target))) throw new Error('browser_field_target_unavailable');
        if (args.kind === 'type' && (target.readOnly
            || (target instanceof HTMLInputElement && !['text','search','email','url','tel','number'].includes(target.type))
            || !(target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target.isContentEditable)))
          throw new Error('browser_field_target_unavailable');
        let option;
        if (args.kind === 'select') {
          if (!(target instanceof HTMLSelectElement) || target.multiple) throw new Error('browser_select_unavailable');
          const options=[...target.options].filter(o=>o.value===args.text);
          if (options.length!==1 || options[0].disabled || options[0].parentElement.disabled)
            throw new Error('browser_option_unavailable');
          option=options[0];
        }
        // Consume before the first side effect; errors never restore this ID.
        state.used.set(args.id, Date.now() + 60000);
        if (args.kind === 'scroll') {
          window.scrollBy(0,args.dy);
        } else if (args.kind === 'click') {
          HTMLElement.prototype.click.call(target);
        } else if (args.kind === 'select') {
          Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(target,option.value);
          target.dispatchEvent(new Event('input',{bubbles:true}));
          target.dispatchEvent(new Event('change',{bubbles:true}));
        } else {
          const form = target.form, action = form ? form.action : '', method = form ? form.method : '';
          const inputType=target.type, editable=target.isContentEditable;
          target.focus({preventScroll:true});
          if (!target.isConnected || target.ownerDocument !== document || target.disabled || target.readOnly || sensitive(target)
              || target.type !== inputType || target.isContentEditable !== editable)
            throw new Error('browser_target_changed_after_focus');
          if (target.isContentEditable) target.textContent = args.text;
          else {
            const prototype = target instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype,'value').set.call(target,args.text);
          }
          target.dispatchEvent(new Event('input',{bubbles:true}));
          target.dispatchEvent(new Event('change',{bubbles:true}));
          if (args.submit) {
            if (!target.isConnected || target.form !== form || !form || form.action !== action || form.method !== method)
              throw new Error('browser_form_changed_after_input');
            HTMLFormElement.prototype.requestSubmit.call(form);
          }
        }
        return JSON.stringify({dispatched:true,verified:false,next:'browser_read_or_screenshot'});
        })()
        """
    }
}
