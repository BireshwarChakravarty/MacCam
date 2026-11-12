import Foundation
import CoreMediaIO

let providerSource = VirtualProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
