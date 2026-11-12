// HOLDER LINK：アプリ内ブラウザ用の Web Bluetooth（navigator.bluetooth）。
// 中身は iPhone の CoreBluetooth に橋渡しする。仕様：https://webbluetoothcg.github.io/web-bluetooth/
(function () {
  if (window.__hlble) return;
  const post = (op, args) => window.webkit.messageHandlers.hlble.postMessage({ op, args: args || {} });

  const BASE = "-0000-1000-8000-00805f9b34fb";
  const NAMES = {
    generic_access: 0x1800, generic_attribute: 0x1801, device_information: 0x180a, battery_service: 0x180f,
    heart_rate: 0x180d, battery_level: 0x2a19, model_number_string: 0x2a24, serial_number_string: 0x2a25,
    firmware_revision_string: 0x2a26, hardware_revision_string: 0x2a27, software_revision_string: 0x2a28,
    manufacturer_name_string: 0x2a29, client_characteristic_configuration: 0x2902,
  };
  function canonical(u) {
    if (typeof u === "number") return ("00000000" + u.toString(16)).slice(-8) + BASE;
    if (typeof u !== "string") throw new TypeError("UUID が不正です");
    const s = u.toLowerCase();
    if (NAMES[s] !== undefined) return canonical(NAMES[s]);
    if (/^[0-9a-f]{4}$/.test(s)) return "0000" + s + BASE;
    if (/^[0-9a-f]{8}$/.test(s)) return s + BASE;
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s)) return s;
    throw new TypeError("UUID が不正です: " + u);
  }
  const BluetoothUUID = {
    canonicalUUID: canonical, getService: canonical, getCharacteristic: canonical, getDescriptor: canonical,
  };

  function toBytes(buf) {
    if (buf instanceof ArrayBuffer) return Array.from(new Uint8Array(buf));
    if (ArrayBuffer.isView(buf)) return Array.from(new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength));
    throw new TypeError("BufferSource が必要です");
  }
  const toView = (arr) => new DataView(new Uint8Array(arr).buffer);
  const domError = (e) => {
    const m = String((e && e.message) || e || "");
    const name = m.startsWith("NotFoundError") ? "NotFoundError"
      : m.startsWith("NotSupportedError") ? "NotSupportedError"
      : m.startsWith("SecurityError") ? "SecurityError" : "NetworkError";
    return new DOMException(m.replace(/^\w+Error:\s*/, ""), name);
  };
  const call = (op, args) => post(op, args).catch((e) => { throw domError(e); });

  class Emitter extends EventTarget {}

  const devices = {};       // id → BluetoothDevice
  const chars = {};         // handle → BluetoothRemoteGATTCharacteristic

  class BluetoothRemoteGATTCharacteristic extends Emitter {
    constructor(service, info) {
      super();
      this.service = service; this.uuid = info.uuid; this._h = info.handle; this.value = null;
      this.properties = Object.freeze(info.props);
      this.oncharacteristicvaluechanged = null;
      chars[info.handle] = this;
    }
    _update(bytes) {
      this.value = toView(bytes);
      const ev = new Event("characteristicvaluechanged", { bubbles: true });
      this.dispatchEvent(ev);
      if (typeof this.oncharacteristicvaluechanged === "function") this.oncharacteristicvaluechanged(ev);
    }
    async readValue() { const r = await call("read", { handle: this._h }); this._update(r); return this.value; }
    async writeValueWithResponse(v) { await call("write", { handle: this._h, bytes: toBytes(v), response: true }); }
    async writeValueWithoutResponse(v) { await call("write", { handle: this._h, bytes: toBytes(v), response: false }); }
    async writeValue(v) {
      const withResp = this.properties.write || !this.properties.writeWithoutResponse;
      await call("write", { handle: this._h, bytes: toBytes(v), response: withResp });
    }
    async startNotifications() { await call("notify", { handle: this._h, on: true }); return this; }
    async stopNotifications() { await call("notify", { handle: this._h, on: false }); return this; }
    async getDescriptor() { throw new DOMException("記述子には未対応です", "NotSupportedError"); }
    async getDescriptors() { return []; }
  }

  class BluetoothRemoteGATTService extends Emitter {
    constructor(device, info) { super(); this.device = device; this.uuid = info.uuid; this._h = info.handle; this.isPrimary = true; }
    async getCharacteristic(uuid) {
      const list = await this.getCharacteristics(uuid);
      if (!list.length) throw new DOMException("キャラクタリスティックがありません", "NotFoundError");
      return list[0];
    }
    async getCharacteristics(uuid) {
      const r = await call("characteristics", { service: this._h, uuid: uuid === undefined ? null : canonical(uuid) });
      return r.map((i) => chars[i.handle] || new BluetoothRemoteGATTCharacteristic(this, i));
    }
  }

  class BluetoothRemoteGATTServer {
    constructor(device) { this.device = device; this.connected = false; }
    async connect() { await call("connect", { id: this.device.id }); this.connected = true; return this; }
    disconnect() { this.connected = false; post("disconnect", { id: this.device.id }).catch(() => {}); }
    async getPrimaryService(uuid) {
      const list = await this.getPrimaryServices(uuid);
      if (!list.length) throw new DOMException("サービスがありません", "NotFoundError");
      return list[0];
    }
    async getPrimaryServices(uuid) {
      if (!this.connected) throw new DOMException("接続されていません", "NetworkError");
      const r = await call("services", { id: this.device.id, uuid: uuid === undefined ? null : canonical(uuid) });
      return r.map((i) => new BluetoothRemoteGATTService(this.device, i));
    }
  }

  class BluetoothDevice extends Emitter {
    constructor(info) {
      super();
      this.id = info.id; this.name = info.name; this.gatt = new BluetoothRemoteGATTServer(this);
      this.ongattserverdisconnected = null;
      devices[info.id] = this;
    }
    _disconnected() {
      this.gatt.connected = false;
      const ev = new Event("gattserverdisconnected", { bubbles: true });
      this.dispatchEvent(ev);
      if (typeof this.ongattserverdisconnected === "function") this.ongattserverdisconnected(ev);
    }
    async forget() { this.gatt.disconnect(); }
    async watchAdvertisements() { throw new DOMException("未対応です", "NotSupportedError"); }
  }

  class Bluetooth extends Emitter {
    async getAvailability() { return await post("availability", {}); }
    async getDevices() {
      const r = await post("knownDevices", {});
      return r.map((i) => devices[i.id] || new BluetoothDevice(i));
    }
    async requestDevice(options) {
      options = options || {};
      if (!options.acceptAllDevices && !(options.filters && options.filters.length)) {
        throw new TypeError("filters か acceptAllDevices が必要です");
      }
      const filters = (options.filters || []).map((f) => ({
        name: f.name || null, namePrefix: f.namePrefix || null,
        services: (f.services || []).map(canonical),
      }));
      const info = await call("requestDevice", {
        filters, acceptAll: !!options.acceptAllDevices,
        optionalServices: (options.optionalServices || []).map(canonical),
      });
      return devices[info.id] || new BluetoothDevice(info);
    }
  }

  const bluetooth = new Bluetooth();
  Object.defineProperty(Navigator.prototype, "bluetooth", { get: () => bluetooth, configurable: true });
  window.BluetoothUUID = BluetoothUUID;
  window.BluetoothDevice = BluetoothDevice;
  window.BluetoothRemoteGATTCharacteristic = BluetoothRemoteGATTCharacteristic;

  // アプリ側から呼ばれる
  window.__hlble = {
    value(handle, bytes) { const c = chars[handle]; if (c) c._update(bytes); },
    disconnected(id) { const d = devices[id]; if (d) d._disconnected(); },
  };
})();
