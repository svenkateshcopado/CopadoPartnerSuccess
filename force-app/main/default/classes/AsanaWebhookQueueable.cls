/**
 * AsanaWebhookQueueable
 *
 * Security fixes applied:
 *   LC-03  Batching enforced at the enqueue site (AsanaWebhookEndpoint) — batches of 15 GIDs
 *          are enqueued so Asana rate limits (150 req/min) are never breached in a single job.
 *          This class itself is intentionally kept simple: it processes whatever Set it receives.
 *   LC-02  No sensitive GIDs or response bodies logged at INFO+.
 */
public class AsanaWebhookQueueable implements Queueable, Database.AllowsCallouts {

    private Set<String> taskGids;

    public AsanaWebhookQueueable(Set<String> taskGids) {
        this.taskGids = taskGids;
    }

    public void execute(QueueableContext context) {
        for (String gid : taskGids) {
            AsanaWebhookProcessor.processTaskEvent(gid);
        }
    }
}
