public class AsanaWebhookQueueable implements Queueable, Database.AllowsCallouts {
    private String taskGid;
    public AsanaWebhookQueueable(String taskGid) {
        this.taskGid = taskGid;
    }
    public void execute(QueueableContext context) {
        AsanaWebhookProcessor.processTaskEvent(taskGid);
    }
}