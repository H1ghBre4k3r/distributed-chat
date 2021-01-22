import ArgumentParser
import Dispatch
import DistributedChat
import Foundation
import LineNoise

#if os(Linux)
import Bluetooth
import BluetoothLinux
#endif

struct DistributedChatCLI: ParsableCommand {
    @Argument(help: "The messaging WebSocket URL of the simulation server to connect to.")
    var simulationMessagingURL: URL = URL(string: "ws://localhost:8080/messaging")!

    @Flag(help: "Use Bluetooth LE-based transport instead of the simulation server. This enables communication with 'real' iOS nodes. Currently only supported on Linux.")
    var bluetooth: Bool = false

    @Option(help: "The username to use.")
    var name: String

    func run() {
        if bluetooth {
            runWithBluetoothLE()
        } else {
            runWithSimulationServer()
        }
    }

    private func runWithBluetoothLE() {
        #if os(Linux)
        print("Initializing Bluetooth Linux stack...")
        
        guard let hostController = BluetoothLinux.HostController.default else { fatalError("No Bluetooth adapters found!") }
        print("Found host controller \(hostController)")
        #else
        print("The Bluetooth stack is currently Linux-only! (TODO: Share the CoreBluetooth-based backend from the iOS app with a potential Mac version of the CLI)")
        #endif
    }

    private func runWithSimulationServer() {
        print("Connecting to \(simulationMessagingURL)...")

        SimulationTransport.connect(url: simulationMessagingURL, name: name) { transport in
            DispatchQueue.main.async {
                print("Connected to \(simulationMessagingURL)")
                try! runREPL(transport: transport)
            }
        }

        // Block the main thread
        dispatchMain()
    }

    private func runREPL(transport: ChatTransport) throws {
        let controller = ChatController(transport: transport)
        let ln = LineNoise()

        controller.update(name: name)
        controller.onAddChatMessage { msg in
            print(">> \(msg.author.name ?? "<anonymous user>"): \(msg.content)\r")
        }

        while let input = try? ln.getLine(prompt: "") {
            ln.addHistory(input)
            print()

            controller.send(content: ChatMessageContent(text: input))
        }

        print()
        Foundation.exit(EXIT_SUCCESS)
    }
}

DistributedChatCLI.main()
