package relay.feature.workspace.hub

import relay.feature.workspace.WorkspaceViewModel
import relay.session.SessionCoordinator
import relay.session.hub.ServerSlot

/**
 * A hub slot the shared workspace can host: one server's coordinator plus the
 * [WorkspaceViewModel] its terminal pane renders. Each app's slot class
 * (Android `AppServerSlot`, Linux `LinuxServerSlot`) implements it.
 */
interface WorkspaceSlot : ServerSlot {
    val coordinator: SessionCoordinator
    val workspaceViewModel: WorkspaceViewModel
}
