/** Test harness surface: the reference phone plus the fixtures that stand up a full stack. */

export { HandshakeRefused, ReinsPhone, type CallResult, type PhoneEvent, type PhoneOptions } from './phone.ts'
export { startStack, waitFor, type Stack, type StackOptions } from './stack.ts'
export { FakeAgent, type RecordedCall } from './fake-agent.ts'
