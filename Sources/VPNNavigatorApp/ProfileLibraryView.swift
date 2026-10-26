import SwiftUI
import VPNNavigatorCore

struct ProfileLibrary: View {
    @EnvironmentObject private var model: AppModel
    let searchRequest: UUID?
    let onImport: () -> Void
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var filtered: [VPNProfile] { model.libraryProfiles }
    private var visibleSelection: VPNProfile? { filtered.first { $0.id == model.selectedID } }
    private var hasFilters: Bool { model.profileLibrary.scope != .all || !model.profileLibrary.query.isEmpty }
    private func clearFilters() { model.profileLibrary.clearFilters(); searchFocused = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            WorkspaceHeading(title: "配置文件",
                subtitle: "管理和编辑 VPN 配置文件",
                symbol: "square.stack.3d.up.fill")
                .padding(.bottom, 4)

            searchToolbar

            HStack(alignment: .top, spacing: 12) {
                libraryColumn

                detailPane

            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 18)
        .onAppear { if searchRequest != nil { searchFocused = true } }
        .onChange(of: searchRequest) { request in if request != nil { searchFocused = true; listFocused = false } }
        .onChange(of: filtered.map(\.id)) { ids in
            if listFocused, model.selectedID.map({ !ids.contains($0) }) ?? true { listFocused = false; searchFocused = true }
        }
    }
    private func focusResult() {
        guard let id = visibleSelection?.id ?? filtered.first?.id else { return }
        searchFocused = false; model.selectedID = id; listFocused = true
    }
    private func moveFocus(from id: UUID, forward: Bool) {
        guard let index = filtered.firstIndex(where: { $0.id == id }) else { return }
        let next = min(max(index + (forward ? 1 : -1), 0), filtered.count - 1)
        model.selectedID = filtered[next].id
    }
    private func scopeButton(_ title: String, scope: ProfileLibraryScope, count: Int) -> some View {
        Button { model.profileLibrary.scope = scope; searchFocused = false } label: {
            Label(title + " (\(count))", systemImage: model.profileLibrary.scope == scope ? "checkmark" : "circle")
        }
    }

    private func profileRow(_ profile: VPNProfile) -> some View {
        Button { searchFocused = false; model.selectedID = profile.id; listFocused = true } label: {
            HStack(spacing: 9) {
                GlassIcon(symbol: "globe",
                          color: profile.isFavorite ?
                            GlassPalette.blue : GlassPalette.cyan,
                          size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.sourceFilename)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 3)
                if model.selectedID == profile.id {
                    Image(systemName: "checkmark").foregroundStyle(GlassPalette.blue).accessibilityHidden(true)
                }
                if profile.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 14))
                }
                if model.activeProfileID == profile.id && model.connected {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                        .accessibilityLabel("已连接")
                } else if !profile.isFavorite {
                    Circle()
                        .fill(Color.secondary.opacity(0.30))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                model.selectedID == profile.id ?
                  GlassPalette.blue.opacity(0.17) :
                  Color.white.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(model.selectedID == profile.id ?
                        GlassPalette.blue.opacity(0.18) : .clear,
                        lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ReferenceQuietButton(cornerRadius: 11))
        .id(profile.id)
        .focusable(false)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
            listFocused && model.selectedID == profile.id ? GlassPalette.blue : .clear, lineWidth: 2).allowsHitTesting(false))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("library-profile-" + profile.id.uuidString)
        .accessibilityLabel(profile.name)
        .accessibilityValue([profile.group, profile.isFavorite ? "已收藏" : "未收藏",
            model.connected && model.activeProfileID == profile.id ? "已连接" : "未连接",
            model.selectedID == profile.id ? "已选择" : "未选择"].joined(separator: "，"))
        .accessibilityHint("选择并查看配置详情；不会发起连接")
        .accessibilityAddTraits(
            model.selectedID == profile.id ? .isSelected : [])
    }

    private var searchToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
            TextField("搜索名称、分组或文件名…", text: $model.profileLibrary.query)
                .focused($searchFocused)
                .accessibilityIdentifier("profile-library-search")
                .accessibilityLabel("搜索配置名称、分组或文件名")
                .onSubmit { focusResult() }
                .font(.system(size: 16))
                .textFieldStyle(.plain)
            if !model.profileLibrary.query.isEmpty {
                Button {
                    model.profileLibrary.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
            .referenceInput(height: 42, focused: searchFocused)
            Button(action: onImport) {
                Label("导入配置", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(height: 26)
            }
            .buttonStyle(ReferencePrimaryButton())
            .tint(GlassPalette.blue)
            .disabled(!model.canChooseProfileFiles)
        }
    }

    private var filterMenuBar: some View {
        HStack(spacing: 6) {
            Menu {
                scopeButton("全部配置", scope: .all, count: model.profiles.count)
                scopeButton("收藏配置", scope: .favorites, count: model.profiles.filter(\.isFavorite).count)
                if !model.libraryGroups.isEmpty {
                    Divider()
                    ForEach(model.libraryGroups) { group in
                        scopeButton(group.name, scope: .group(group.name), count: group.count)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.profileLibrary.scope.title).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }.menuIndicator(.hidden).buttonStyle(.plain).help("按收藏或分组筛选配置")
                .accessibilityLabel("配置筛选").accessibilityValue(model.profileLibrary.scope.title)
            Spacer(minLength: 0)
            Menu {
                ForEach(ProfileLibrarySort.allCases) { sort in
                    Button { model.profileLibrary.sort = sort } label: {
                        Label(sort.title, systemImage: model.profileLibrary.sort == sort ? "checkmark" : "circle")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.menuIndicator(.hidden).buttonStyle(.plain)
                .help("排序：" + model.profileLibrary.sort.title).accessibilityLabel("配置排序")
        }.padding(.horizontal, 6)
    }

    private var filterSummary: some View {
        HStack {
            Text("显示 \(filtered.count) / \(model.profiles.count) 个 · " + model.profileLibrary.sort.title)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if hasFilters {
                Button("清除") { clearFilters() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(GlassPalette.blue).help("清除搜索与分组筛选")
            }
        }.padding(.horizontal, 6).padding(.bottom, 3)
    }

    private var profileList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(filtered) { profile in profileRow(profile) }
            }
        }
        .onChange(of: model.selectedID) { id in
            if listFocused, let id { proxy.scrollTo(id, anchor: .center) }
        }
        }
        .focusable()
        .focused($listFocused)
        .onMoveCommand { direction in
            guard listFocused, let id = visibleSelection?.id else { return }
            if direction == .down { moveFocus(from: id, forward: true) }
            else if direction == .up { moveFocus(from: id, forward: false) }
        }
        .onChange(of: listFocused) { focused in
            if focused, visibleSelection == nil, let first = filtered.first { model.selectedID = first.id }
        }
        .accessibilityLabel("配置列表")
    }

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterMenuBar

            filterSummary

            profileList

            if filtered.isEmpty {
                Label(model.profiles.isEmpty ? "尚无配置" : "没有匹配的配置", systemImage: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 15)
    }

    private var detailPane: some View {
        ZStack {
            if let profile = model.selected {
                ProfileDetail(profile: profile, isVisible: visibleSelection != nil).id(profile.id)
                    .opacity(visibleSelection == nil ? 0 : 1)
                    .disabled(visibleSelection == nil)
                    .allowsHitTesting(visibleSelection != nil)
                    .accessibilityHidden(visibleSelection == nil)
            }
            if visibleSelection == nil {
                VStack(spacing: 10) {
                    GlassIcon(symbol: "square.stack.3d.up", size: 45)
                    Text(model.selected == nil ? "选择配置文件" : "当前选择不在筛选结果中").font(.headline)
                    Text(model.profiles.isEmpty ? "点击右上角「导入配置」以添加 .ovpn 文件" :
                         filtered.isEmpty ? "请调整搜索词或清除筛选。" : "从左侧列表选择要查看的配置。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    if model.selected != nil && hasFilters {
                        Button("显示当前选择") { clearFilters() }.buttonStyle(ReferenceSecondaryButton())
                    } else if hasFilters {
                        Button("清除筛选") { clearFilters() }.buttonStyle(ReferenceSecondaryButton())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 16)
    }
}
