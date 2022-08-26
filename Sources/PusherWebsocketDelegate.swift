import Foundation
import Starscream

extension PusherConnection: WebSocketDelegate {

  public func didReceive(event: WebSocketEvent, client: WebSocket) {
    switch event {
    case .connected:
      websocketDidConnect(socket: client)
    case .disconnected(_, _):
      websocketDidDisconnect(socket: client, error: nil)
    case .text(let string):
      websocketDidReceiveMessage(socket: client, text: string)
    case .binary(let data):
      websocketDidReceiveData(socket: client, data: data)
    case .ping:
      self.delegate?.debugLog?(message: "[PUSHER DEBUG] Ping")
    case .pong:
      self.delegate?.debugLog?(message: "[PUSHER DEBUG] Websocket received pong")
      resetActivityTimeoutTimer()
    case .viabilityChanged(let viability):
      self.delegate?.debugLog?(message: "[PUSHER DEBUG] viabilityChanged: \(viability)")

    case .reconnectSuggested(let suggestion):
      self.delegate?.debugLog?(message: "[PUSHER DEBUG] reconnectSuggested: \(suggestion)")
    case .cancelled:
      websocketDidDisconnect(socket: client, error: nil)
    case .error(let error):
      websocketDidDisconnect(socket: client, error: error)
    }
  }

    /**
        Delegate method called when a message is received over a websocket

        - parameter ws:   The websocket that has received the message
        - parameter text: The message received over the websocket
    */
    private func websocketDidReceiveMessage(socket ws: WebSocketClient, text: String) {
        self.delegate?.debugLog?(message: "[PUSHER DEBUG] websocketDidReceiveMessage \(text)")

        guard let payload = PusherParser.getPusherEventJSON(from: text),
            let event = payload["event"] as? String
        else {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Unable to handle incoming Websocket message \(text)")
            return
        }

        if event == "pusher:error" {
            guard let error = PusherError(jsonObject: payload) else {
                self.delegate?.debugLog?(message: "[PUSHER DEBUG] Unable to handle incoming error \(text)")
                return
            }
            self.handleError(error: error)
        } else {
            self.eventQueue.enqueue(json: payload)
        }
    }

    /**
        Delegate method called when a websocket disconnected

        - parameter ws:    The websocket that disconnected
        - parameter error: The error, if one exists, when disconnected
    */
    private func websocketDidDisconnect(socket ws: WebSocketClient, error: Error?) {
        // Handles setting channel subscriptions to unsubscribed wheter disconnection
        // is intentional or not
        if connectionState == .disconnecting || connectionState == .connected {
            for (_, channel) in self.channels.channels {
                channel.subscribed = false
            }
        }

        self.connectionEstablishedMessageReceived = false
        self.socketConnected = false

        updateConnectionState(to: .disconnected)

        guard !intentionalDisconnect else {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Deliberate disconnection - skipping reconnect attempts")
            return
        }

        // Handle error (if any)

        if let error = error {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Websocket is disconnected. Error (code: \((error as NSError).code)): \(error.localizedDescription)")
        } else {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Websocket is disconnected but no error received")
        }

        // Attempt reconnect if possible

        guard self.options.autoReconnect else {
            return
        }

        guard reconnectAttemptsMax == nil || reconnectAttempts < reconnectAttemptsMax! else {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Max reconnect attempts reached")
            return
        }

        if let reachability = self.reachability, reachability.connection == .unavailable {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Network unreachable so reconnect likely to fail")
        }

        attemptReconnect()
    }

    /**
        Attempt to reconnect triggered by a disconnection
    */
    internal func attemptReconnect() {
        guard connectionState != .connected else {
            return
        }

        guard reconnectAttemptsMax == nil || reconnectAttempts < reconnectAttemptsMax! else {
            return
        }

        if connectionState != .reconnecting {
            updateConnectionState(to: .reconnecting)
        }

        let reconnectInterval = Double(reconnectAttempts * reconnectAttempts)

        let timeInterval = maxReconnectGapInSeconds != nil ? min(reconnectInterval, maxReconnectGapInSeconds!)
                                                           : reconnectInterval

        if reconnectAttemptsMax != nil {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Waiting \(timeInterval) seconds before attempting to reconnect (attempt \(reconnectAttempts + 1) of \(reconnectAttemptsMax!))")
        } else {
            self.delegate?.debugLog?(message: "[PUSHER DEBUG] Waiting \(timeInterval) seconds before attempting to reconnect (attempt \(reconnectAttempts + 1))")
        }

        reconnectTimer = Timer.scheduledTimer(
            timeInterval: timeInterval,
            target: self,
            selector: #selector(connect),
            userInfo: nil,
            repeats: false
        )
        reconnectAttempts += 1
    }

    /**
        Delegate method called when a websocket connected

        - parameter ws:    The websocket that connected
    */
    private func websocketDidConnect(socket ws: WebSocketClient) {
        self.socketConnected = true
    }

    private func websocketDidReceiveData(socket ws: WebSocketClient, data: Data) {}
}
