import Foundation
import Testing
@testable import DictationCore

struct DemoModeTests {
    @Test func taskRequestsBecomeAworkTasks() {
        let plan = DemoPlanner.plan("Leg eine Aufgabe an: Release Notes prüfen, bis Freitag")
        #expect(plan.actions.first?.kind == .aworkTask)
        #expect(plan.actions.first?.taskName == "Release Notes prüfen")
        #expect(plan.actions.first?.projectId == "p-release")
        #expect(plan.actions.first?.due.count == 10)
    }

    @Test func questionsGoToTheAgent() async throws {
        let plan = DemoPlanner.plan("Give me my Servicedesk tickets from today")
        #expect(plan.actions.first?.kind == .agent)
        let reply = try await DemoPlanner().complete(messages: [ChatMessage(role: "user", content: "<request>Was ist heute fällig?</request>")],
                                                     maxTokens: 100, schema: [:])
        let decoded = try JSONDecoder().decode(AssistantPlan.self, from: Data(reply.utf8))
        #expect(decoded.isOnlyQuestions)
    }

    @Test func agentAnswersFitTheQuestion() {
        let tickets = DemoAgent.answer(to: "Use the servicedesk tools to list today's tickets")
        #expect(tickets.answer.contains("SD-1042"))
        #expect(tickets.tools.first == "mcp__servicedesk__sd_queue")
        #expect(DemoAgent.answer(to: "Which awork tasks are due?").answer.contains("[NW] Release 2.4"))
    }

    @Test func polarionBacklogRunsOnFixtures() async throws {
        let agent = DemoAgent()
        let connection = PolarionBacklog.Connection(server: DemoMode.polarionServer, serverName: "polarion-openapi")
        let projects = try await PolarionBacklog.projects(agent: agent, connection: connection)
        #expect(projects.contains { $0.id == "NW_InfusionPump" })
        let result = try await PolarionBacklog.draft(items: ["Mia prüft den PDF-Export", "Paul ergänzt den Audit Trail"], project: "NW_Backlog",
                                                     kind: .automatic, meetingTitle: "Release 2.4 Sync", meetingDate: Date(), notes: "",
                                                     context: "", answers: [], agent: agent, connection: connection)
        #expect(result.drafts.map(\.title) == ["Mia prüft den PDF-Export", "Paul ergänzt den Audit Trail"])
        let created = try await PolarionBacklog.create(result.drafts, project: "NW_Backlog", agent: agent, connection: connection)
        #expect(created.created.map(\.id) == ["NW-231", "NW-232"])
        #expect(created.problems.isEmpty)
    }

    @Test func aworkAnswersLikeTheAPI() async throws {
        let awork = DemoAwork()
        let projects = try await awork.answer(method: "GET", path: "projects?pageSize=500&page=1", body: nil) as? [[String: Any]]
        #expect(projects?.count == 5)
        let nextPage = try await awork.answer(method: "GET", path: "projects?pageSize=500&page=2", body: nil) as? [[String: Any]]
        #expect(nextPage?.isEmpty == true)
        let created = try await awork.answer(method: "POST", path: "tasks", body: ["name": "Release Notes prüfen", "entityId": "p-release"])
            as? [String: Any]
        #expect(created?["taskIdentifier"] as? String == "NWR-101")
        let tasks = try await awork.answer(method: "GET", path: "projects/p-release/projecttasks?pageSize=500&page=1", body: nil)
            as? [[String: Any]]
        #expect(tasks?.contains { $0["name"] as? String == "Release Notes prüfen" } == true)
    }
}
