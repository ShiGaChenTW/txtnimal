import Foundation

@objc protocol PluginRunnerXPCProtocol {
    func execute(request: String, source: String?, inputJSON: String?, probePath: String?,
                 withReply reply: @escaping (String) -> Void)
}

let pluginRunnerSpikeServiceName = "app.taskstxt.PluginRunnerSpikeService"
