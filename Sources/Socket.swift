//
//  Socket.swift
//  SwiftPhoenixClient
//

import Swift
import Starscream
import Foundation

public class Socket: WebSocketDelegate {
    var conn: WebSocket?
    var endPoint: String?
    var channels: [Channel] = []

    var sendBuffer: [Void] = []
    var sendBufferTimer = Timer()
    let flushEveryMs = 1.0

    var reconnectTimer = Timer()
    let reconnectAfterMs = 1.0

    var heartbeatTimer = Timer()
    let heartbeatDelay = 30.0
    
    public var onClose: ((Socket, NSError?) -> Void)?

    var messageReference: UInt64 = UInt64.min // 0 (max: 18,446,744,073,709,551,615)

    /**
     Initializes a Socket connection
     - parameter domainAndPort: Phoenix server root path and proper port
     - parameter path:          Websocket path on Phoenix Server
     - parameter transport:     Transport for Phoenix.Server - traditionally "websocket"
     - parameter prot:          Connection protocol - default is HTTP
     - returns: Socket
     */
    public init(domainAndPort:String, path:String, transport:String, prot:String = "http", params: [String: Any]? = nil) {
        self.endPoint = Path.endpointWithProtocol(prot: prot, domainAndPort: domainAndPort, path: path, transport: transport)

        if let parameters = params {
            self.endPoint = self.endPoint! + "?" + parameters.map({ "\($0.0)=\($0.1)" }).joined(separator: "&")
        }

        resetBufferTimer()
        reconnect()
    }

    /**
     Closes socket connection
     - parameter callback: Function to run after close
     */
    public func close(callback: (() -> ()) = {}) {
        if let connection = self.conn {
            connection.delegate = nil
            connection.disconnect()
        }

        invalidateTimers()
        callback()
    }

    /**
     Invalidate open timers to allow socket to be deallocated when closed
     */
    func invalidateTimers() {
        heartbeatTimer.invalidate()
        reconnectTimer.invalidate()
        sendBufferTimer.invalidate()

        heartbeatTimer = Timer()
        reconnectTimer = Timer()
        sendBufferTimer = Timer()
    }

    /**
     Initializes a 30s timer to let Phoenix know this device is still alive
     */
    func startHeartbeatTimer() {
        heartbeatTimer.invalidate()
        heartbeatTimer = Timer.scheduledTimer(timeInterval: heartbeatDelay, target: self, selector: #selector(heartbeat), userInfo: nil, repeats: true)
    }

    /**
     Heartbeat payload (Message) to send with each pulse
     */
    @objc func heartbeat() {
        let message = Message(message: ["body": "Pong"] as Any)
        let payload = Payload(topic: "phoenix", event: "heartbeat", message: message)
        send(data: payload)
    }

    /**
     Reconnects to a closed socket connection
     */
    @objc public func reconnect() {
        close() {
            self.conn = WebSocket(url: NSURL(string: self.endPoint!)! as URL)
            if let connection = self.conn {
                connection.delegate = self
                connection.connect()
            }
        }
    }

    /**
     Resets the message buffer timer and invalidates any existing ones
     */
    func resetBufferTimer() {
        sendBufferTimer.invalidate()
        sendBufferTimer = Timer.scheduledTimer(timeInterval: flushEveryMs, target: self, selector: #selector(flushSendBuffer), userInfo: nil, repeats: true)
        sendBufferTimer.fire()
    }

    /**
     Kills reconnect timer and joins all open channels
     */
    func onOpen() {
        reconnectTimer.invalidate()
        startHeartbeatTimer()
        rejoinAll()
    }

    /**
     Starts reconnect timer onClose
     - parameter event: String event name
     */
    func onClose(event: String, error: NSError? = nil) {
        reconnectTimer.invalidate()
        reconnectTimer = Timer.scheduledTimer(timeInterval: reconnectAfterMs, target: self, selector: #selector(reconnect), userInfo: nil, repeats: true)
        
        if let callback = self.onClose {
            callback(self, error)
        }
    }

    /**
     Triggers error event
     - parameter error: NSError
     */
    func onError(error: NSError) {
      Logger.debug(message: "Error: \(error)")
        for chan in channels {
            let msg = Message(message: ["body": error.localizedDescription] as Any)
            chan.trigger(triggerEvent: "error", msg: msg)
        }
    }

    /**
     Indicates if connection is established
     - returns: Bool
     */
    public func isConnected() -> Bool {
        if let connection = self.conn {
            return connection.isConnected
        } else {
            return false
        }

    }

    /**
     Rejoins all Channel instances
     */
    func rejoinAll() {
        for chan in channels {
            rejoin(chan: chan as Channel)
        }
    }

    /**
     Rejoins a given Phoenix Channel
     - parameter chan: Channel
     */
    func rejoin(chan: Channel) {
        chan.reset()
        if let topic = chan.topic, let joinMessage = chan.message {
            let payload = Payload(topic: topic, event: "phx_join", message: joinMessage)
            send(data: payload)
            chan.callback(chan)
        }
    }

    /**
     Joins socket
     - parameter topic:    String topic name
     - parameter message:  Message payload
     - parameter callback: Function to trigger after join
     */
    public func join(topic: String, message: Message, callback: @escaping ((Any) -> Void)) {
        let chan = Channel(topic: topic, message: message, callback: callback, socket: self)
        channels.append(chan)
        if isConnected() {
          Logger.debug(message: "joining")
            rejoin(chan: chan)
        }
    }

    /**
     Leave open socket
     - parameter topic:   String topic name
     - parameter message: Message payload
     */
    public func leave(topic: String, message: Message) {
        let leavingMessage = Message(subject: "status", body: "leaving" as Any)
        let payload = Payload(topic: topic, event: "phx_leave", message: leavingMessage)
        send(data: payload)
        var newChannels: [Channel] = []
        for chan in channels {
            let c = chan as Channel
            if !c.isMember(topic: topic) {
                newChannels.append(c)
            }
        }
        channels = newChannels
    }

    /**
     Send payload over open socket
     - parameter data: Payload
     */
    public func send(data: Payload) {
        let callback = {
            (payload: Payload) -> Void in
            if let connection = self.conn {
                let json = self.payloadToJson(payload: payload)
              Logger.debug(message: "json: \(json)")
                connection.write(string: json)
            }
        }
        if isConnected() {
            callback(data)
        } else {
            sendBuffer.append(callback(data))
        }
    }

    /**
     Flush message buffer
     */
    @objc func flushSendBuffer() {
        if isConnected() && sendBuffer.count > 0 {
            for callback in sendBuffer {
                callback
            }
            sendBuffer = []
            resetBufferTimer()
        }
    }

    /**
     Trigger event on message received
     - parameter payload: Payload
     */
    func onMessage(payload: Payload) {
        let (topic, event, message) = (payload.topic, payload.event, payload.message)
        for chan in channels {
            if chan.isMember(topic: topic) {
                chan.trigger(triggerEvent: event, msg: message)
            }
        }
    }

    // WebSocket Delegate Methods

    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
      Logger.debug(message: "socket message: \(text)")

        guard let data = text.data(using: String.Encoding.utf8),
            let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let jsonObject = json as? [String: AnyObject] else {
            Logger.debug(message: "Unable to parse JSON: \(text)")
                return
        }

        guard let topic = jsonObject["topic"] as? String, let event = jsonObject["event"] as? String,
            let msg = jsonObject["payload"] as? [String: AnyObject] else {
              Logger.debug(message: "No phoenix message: \(text)")
                return
        }
        Logger.debug(message: "JSON Object: \(jsonObject)")
        let messagePayload = Payload(topic: topic, event: event, message: Message(message: msg))
        onMessage(payload: messagePayload)
    }

    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
      Logger.debug(message: "got some data: \(data.count)")
    }

    public func websocketDidDisconnect(socket: WebSocketClient, error: NSError?) {
        if let err = error { onError(error: err as NSError) }
        Logger.debug(message: "socket closed: \(error?.localizedDescription ?? "Unknown error")")
        onClose(event: "reason: \(error?.localizedDescription ?? "Unknown error")", error:error))
    }

    public func websocketDidConnect(socket: WebSocketClient) {
      Logger.debug(message: "socket opened")
        onOpen()
    }

    public func websocketDidWriteError(error: NSError?) {
        onError(error: error!)
    }

    func unwrappedJsonString(string: String?) -> String {
        if let stringVal = string {
            return stringVal
        } else {
            return ""
        }
    }

    func makeRef() -> UInt64 {
        let newRef = messageReference + 1
        messageReference = (newRef == UInt64.max) ? 0 : newRef
        return newRef
    }

    func payloadToJson(payload: Payload) -> String {
        let ref = makeRef()
        var json: [String: Any] = [
            "topic": payload.topic,
            "event": payload.event,
            "ref": "\(ref)"
        ]

        if let msg = payload.message.message {
            json["payload"] = msg
        } else {
            json["payload"] = payload.message.toDictionary()
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
            let jsonString = String(data: jsonData, encoding: String.Encoding.utf8) else {
                return ""
        }

        return jsonString
    }
}
