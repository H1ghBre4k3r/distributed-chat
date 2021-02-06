import Foundation
import Logging

fileprivate let log = Logger(label: "DistributedChat.ChatController")

/// The central structure of the distributed chat.
/// Carries out actions, e.g. on the user's behalf.
@available(iOS 13, *)
public class ChatController {
    private let transportWrapper: ChatTransportWrapper<ChatProtocol.Message>
    private var addChatMessageListeners: [(ChatMessage) -> Void] = []
    private var updatePresenceListeners: [(ChatPresence) -> Void] = []
    private var deleteMessageListeners: [(ChatDeletion) -> Void] = []
    private var userFinders: [(UUID) -> ChatUser?] = []
    public var emitAllReceivedChatMessages: Bool = false // including encrypted ones/those not for me

    private let privateKeys: ChatCryptoKeys.Private
    private var presenceTimer: RepeatingTimer?
    public private(set) var presence: ChatPresence

    public var me: ChatUser { presence.user }

    public init(me: ChatUser = ChatUser(), transport: ChatTransport) {
        let privateKeys = ChatCryptoKeys.Private()
        self.privateKeys = privateKeys

        presence = ChatPresence(user: me)
        presence.user.publicKeys = privateKeys.publicKeys
        
        transportWrapper = ChatTransportWrapper(transport: transport)
        transportWrapper.onReceive(handleReceive)
        
        // Broadcast the presence every 10 seconds
        presenceTimer = RepeatingTimer(interval: 10.0) { [weak self] in
            self?.broadcastPresence()
        }
    }

    private func handleReceive(_ protoMessage: ChatProtocol.Message) {
        // TODO: Rebroadcast message and make sure that
        //       incoming messages did NOT origin from us
        //       (i.e. went in a loop), as otherwise the
        //       listeners would be fired twice with this
        //       message.
        // What happens if one message takes two different
        // path to the same device?
        if !protoMessage.visitedUsers.contains(me.id) {
            var visitedUsers = Set(protoMessage.visitedUsers)
            visitedUsers.insert(me.id)
            // Rebroadcast message
            transportWrapper.broadcast(ChatProtocol.Message(visitedUsers: visitedUsers, addedChatMessages: protoMessage.addedChatMessages, logicalClock: protoMessage.logicalClock))
                        
            // Handle message
            

            updateClock(logicalClock: protoMessage.logicalClock)

            for message in protoMessage.addedChatMessages ?? [] where message.isReceived(by: me.id) {
                for listener in addChatMessageListeners {
                    listener(message)
                }
            }
        }

        for encryptedMessage in protoMessage.addedChatMessages ?? [] where encryptedMessage.isReceived(by: me.id) || emitAllReceivedChatMessages {
            let chatMessage = encryptedMessage.decryptedIfNeeded(with: privateKeys, keyFinder: findPublicKeys(for:))

            if !chatMessage.isEncrypted || emitAllReceivedChatMessages {
                for listener in addChatMessageListeners {
                    listener(chatMessage)
                }
            }
        }
        // Handle presence updates
        
        for presence in protoMessage.updatedPresences ?? [] {
            for listener in updatePresenceListeners {
                listener(presence)
            }
        }

        for deletion in protoMessage.deleteMessages ?? [] {
            for listener in deleteMessageListeners {
                listener(deletion)
            }
        }
    }

    public func send(content: String, on channel: ChatChannel? = nil, attaching attachments: [ChatAttachment]? = nil, replyingTo repliedToMessageId: UUID? = nil) {
        let chatMessage = ChatMessage(
            author: me,
            content: .text(content),
            channel: channel,
            attachments: attachments,
            repliedToMessageId: repliedToMessageId
        )
        let encryptedMessage = chatMessage.encryptedIfNeeded(with: privateKeys, keyFinder: findPublicKeys(for:))
        incrementClock()
        let protoMessage = ChatProtocol.Message(addedChatMessages: [encryptedMessage], logicalClock: presence.user.logicalClock)

        transportWrapper.broadcast(protoMessage)
        
        for listener in addChatMessageListeners {
            listener(chatMessage)
        }
    }

    public func update(presence: ChatPresence) {
        self.presence = presence
        
        for listener in updatePresenceListeners {
            listener(presence)
        }
    }
    
    public func update(name: String) {
        var newPresence = presence
        newPresence.user.name = name
        update(presence: newPresence)
    }

    private func findUser(for userId: UUID) -> ChatUser? {
        userFinders.lazy.compactMap { $0(userId) }.first
    }

    private func findPublicKeys(for userId: UUID) -> ChatCryptoKeys.Public? {
        findUser(for: userId)?.publicKeys
    }

    private func updateClock(logicalClock: Int) {
        var newPresence = presence
        newPresence.user.logicalClock = max(newPresence.user.logicalClock, logicalClock) + 1
        update(presence: newPresence)
    }

    private func incrementClock() {
        var newPresence = presence
        newPresence.user.logicalClock = newPresence.user.logicalClock + 1
        update(presence: newPresence)
    }
    
    private func broadcastPresence() {
        log.debug("Broadcasting presence: \(presence.status) (\(presence.info))")
        incrementClock()
        transportWrapper.broadcast(ChatProtocol.Message(updatedPresences: [presence], logicalClock: presence.user.logicalClock))
    }

    // TODO: Delete
    // private func updateVectorClock(vectorClock: Dictionary<UUID,Int>) {
    //     // TODO: Consider deleting old entries
    //     var newMe = me
    //     for (id, time) in vectorClock {
    //         if newMe.vectorClock.keys.contains(id) {
    //             if time > newMe.vectorClock[id]! {
    //                 newMe.vectorClock[id] = time
    //             }
    //         } else {
    //             newMe.vectorClock[id] = time
    //         }
    //     }
    //     update(me: newMe)
    // }

    // TODO: Delete
    // private func compareVectorTimes(vectorTime1: Dictionary<UUID,Int>, vectorTime2: Dictionary<UUID,Int>){
    //     var returnValue: Int = 0
    //     for id in vectorTime1.intersection(vectorTime2) {
    //         if time1[key] < time2[key] {
    //             if return_value <= 0 {
    //                 return_value = -1
    //             } else {
    //                 return 0
    //             }
    //         } else if time1[key] > time2[key]{:
    //             if return_value >= 0 {
    //                 return_value = 1
    //             } else {
    //                 return 0
    //             }
    //         }
    //     }
    //     return return_value
    // }

    public func onAddChatMessage(_ handler: @escaping (ChatMessage) -> Void) {
        addChatMessageListeners.append(handler)
    }
    
    public func onUpdatePresence(_ handler: @escaping (ChatPresence) -> Void) {
        updatePresenceListeners.append(handler)
    }

    public func onDeleteMessage(_ handler: @escaping (ChatDeletion) -> Void) {
        deleteMessageListeners.append(handler)
    }

    public func onFindUser(_ handler: @escaping (UUID) -> ChatUser?) {
        userFinders.append(handler)
    }
}
