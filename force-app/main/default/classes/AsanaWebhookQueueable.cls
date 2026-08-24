public class AsanaWebhookQueueable implements Queueable, Database.AllowsCallouts {

    private Set<String> taskGids;

    // ── New constructor: accepts a full Set of GIDs ───────────────────────────
    public AsanaWebhookQueueable(Set<String> taskGids) {
        this.taskGids = taskGids;
    }

    public void execute(QueueableContext context) {
        for (String gid : taskGids) {
            AsanaWebhookProcessor.processTaskEvent(gid);
        }
    }
}
