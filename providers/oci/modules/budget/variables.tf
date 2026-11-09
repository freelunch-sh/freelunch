variable "tenancy_id" {
  description = "Tenancy OCID. Budgets live in the root compartment and cover the whole tenancy."
  type        = string
}

variable "name" {
  description = "Name prefix."
  type        = string
  default     = "freelunch"
}

variable "amount" {
  description = "Monthly budget in the tenancy's currency. The Always Free tier costs nothing, so the default is 1."
  type        = number
  default     = 1

  validation {
    condition     = var.amount > 0
    error_message = "amount must be above 0."
  }
}

variable "alert_emails" {
  description = "Who is emailed when spend reaches the threshold. An alert rule needs a recipient, so with [] no budget is created."
  type        = list(string)
  default     = []
}

variable "forecast_threshold_percent" {
  description = "Also alert when OCI forecasts that the month will reach this percent of the budget. 0 turns the forecast alert off."
  type        = number
  default     = 100
}
