import { useState } from "react";

import { ServiceConfigurationForm } from "@/components/ServiceConfigurationForm";
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { AGENT_LANGUAGES } from "@/constants/languages";
import type { WorkflowConfigurations } from "@/types/workflow-configurations";

interface ModelConfigurationDialogProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    workflowConfigurations: WorkflowConfigurations | null;
    workflowName: string;
    onSave: (configurations: WorkflowConfigurations, workflowName: string) => Promise<void>;
}

// Sentinel for "no forced language" — the agent behaves normally (follows the
// selected providers and the prompt) with no language enforcement.
const NO_LANGUAGE = "none";

export const ModelConfigurationDialog = ({
    open,
    onOpenChange,
    workflowConfigurations,
    workflowName,
    onSave,
}: ModelConfigurationDialogProps) => {
    const [language, setLanguage] = useState<string>(
        workflowConfigurations?.language || NO_LANGUAGE,
    );

    return (
        <Dialog open={open} onOpenChange={onOpenChange}>
            <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
                <DialogHeader>
                    <DialogTitle>Model Configuration</DialogTitle>
                    <DialogDescription>
                        Override global model settings for this workflow. Toggle individual services to customize.
                    </DialogDescription>
                </DialogHeader>

                <div className="space-y-2">
                    <Label htmlFor="agent-language">Agent Language</Label>
                    <Select value={language} onValueChange={setLanguage}>
                        <SelectTrigger id="agent-language">
                            <SelectValue placeholder="Select language" />
                        </SelectTrigger>
                        <SelectContent>
                            <SelectItem value={NO_LANGUAGE}>No forced language</SelectItem>
                            {AGENT_LANGUAGES.map((lang) => (
                                <SelectItem key={lang.code} value={lang.code}>
                                    {lang.label}
                                </SelectItem>
                            ))}
                        </SelectContent>
                    </Select>
                    <p className="text-sm text-muted-foreground">
                        The agent listens, speaks, and responds only in this language, using your selected STT/TTS
                        providers. Choose &quot;No forced language&quot; to disable it.
                    </p>
                </div>

                <ServiceConfigurationForm
                    mode="override"
                    currentOverrides={workflowConfigurations?.model_overrides}
                    submitLabel="Save"
                    onSave={async (config) => {
                        await onSave(
                            {
                                ...workflowConfigurations,
                                model_overrides: config.model_overrides as WorkflowConfigurations["model_overrides"],
                                language: language === NO_LANGUAGE ? null : language,
                            } as WorkflowConfigurations,
                            workflowName,
                        );
                        onOpenChange(false);
                    }}
                />
            </DialogContent>
        </Dialog>
    );
};
