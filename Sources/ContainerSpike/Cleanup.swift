import ContainerKit
import Foundation

enum Cleanup {
    static func run(images: Bool) async throws {
        let client = Spike.client
        for container in try await client.listContainers(labels: ["bellocode.spike=1"]) {
            try await client.removeContainer(container.id, force: true, volumes: true)
            log("removed container \(container.names.first ?? container.id)")
        }
        for volume in try await client.listVolumes(labels: ["bellocode.spike=1"]) {
            try await client.removeVolume(volume, force: true)
            log("removed volume \(volume)")
        }
        for network in try await client.listNetworks(labels: ["bellocode.spike=1"]) {
            try await client.removeNetwork(network)
            log("removed network \(network)")
        }
        if images, try await client.inspectImage(Spike.imageTag) != nil {
            try await client.removeImage(Spike.imageTag, force: true)
            log("removed image \(Spike.imageTag)")
        }
    }
}
