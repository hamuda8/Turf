//! Every page of the app, by name. A page is a module in pages/ (see core.zig for its shape).

const std = @import("std");
const core = @import("core.zig");

pub const mods = struct {
    pub const signin = @import("pages/signin.zig");
    pub const landing = @import("pages/landing.zig");
    pub const lookup = @import("pages/lookup.zig");
    pub const public_track = @import("pages/public_track.zig");
    pub const not_found = @import("pages/not_found.zig");
    pub const home = @import("pages/home.zig");
    pub const create_org = @import("pages/create_org.zig");
    pub const app_track = @import("pages/app_track.zig");
    pub const direct_send = @import("pages/direct_send.zig");
    pub const direct_parcels = @import("pages/direct_parcels.zig");
    pub const direct_parcel = @import("pages/direct_parcel.zig");
    pub const invite = @import("pages/invite.zig");
    pub const c_dashboard = @import("pages/c_dashboard.zig");
    pub const c_shipments = @import("pages/c_shipments.zig");
    pub const c_shipment = @import("pages/c_shipment.zig");
    pub const dispatch = @import("pages/dispatch.zig");
    pub const fleet = @import("pages/fleet.zig");
    pub const scan = @import("pages/scan.zig");
    pub const alerts = @import("pages/alerts.zig");
    pub const c_finance = @import("pages/c_finance.zig");
    pub const requests = @import("pages/requests.zig");
    pub const claims = @import("pages/claims.zig");
    pub const reports = @import("pages/reports.zig");
    pub const hubs = @import("pages/hubs.zig");
    pub const hub = @import("pages/hub.zig");
    pub const c_settings = @import("pages/c_settings.zig");
    pub const team = @import("pages/team.zig");
    pub const branding = @import("pages/branding.zig");
    pub const audit = @import("pages/audit.zig");
    pub const driver = @import("pages/driver.zig");
    pub const task = @import("pages/task.zig");
    pub const m_dashboard = @import("pages/m_dashboard.zig");
    pub const m_shipments = @import("pages/m_shipments.zig");
    pub const m_new = @import("pages/m_new.zig");
    pub const m_bulk = @import("pages/m_bulk.zig");
    pub const m_shipment = @import("pages/m_shipment.zig");
    pub const developers = @import("pages/developers.zig");
    pub const m_finance = @import("pages/m_finance.zig");
    pub const m_settings = @import("pages/m_settings.zig");
};

pub const Id = enum {
    none,
    signin,
    landing,
    lookup,
    public_track,
    not_found,
    home,
    create_org,
    app_track,
    direct_send,
    direct_parcels,
    direct_parcel,
    invite,
    c_dashboard,
    c_shipments,
    c_shipment,
    dispatch,
    fleet,
    scan,
    alerts,
    c_finance,
    requests,
    claims,
    reports,
    hubs,
    hub,
    c_settings,
    team,
    branding,
    audit,
    driver,
    task,
    m_dashboard,
    m_shipments,
    m_new,
    m_bulk,
    m_shipment,
    developers,
    m_finance,
    m_settings,
};

pub const Page = union(Id) {
    none,
    signin: mods.signin.S,
    landing: mods.landing.S,
    lookup: mods.lookup.S,
    public_track: mods.public_track.S,
    not_found: mods.not_found.S,
    home: mods.home.S,
    create_org: mods.create_org.S,
    app_track: mods.app_track.S,
    direct_send: mods.direct_send.S,
    direct_parcels: mods.direct_parcels.S,
    direct_parcel: mods.direct_parcel.S,
    invite: mods.invite.S,
    c_dashboard: mods.c_dashboard.S,
    c_shipments: mods.c_shipments.S,
    c_shipment: mods.c_shipment.S,
    dispatch: mods.dispatch.S,
    fleet: mods.fleet.S,
    scan: mods.scan.S,
    alerts: mods.alerts.S,
    c_finance: mods.c_finance.S,
    requests: mods.requests.S,
    claims: mods.claims.S,
    reports: mods.reports.S,
    hubs: mods.hubs.S,
    hub: mods.hub.S,
    c_settings: mods.c_settings.S,
    team: mods.team.S,
    branding: mods.branding.S,
    audit: mods.audit.S,
    driver: mods.driver.S,
    task: mods.task.S,
    m_dashboard: mods.m_dashboard.S,
    m_shipments: mods.m_shipments.S,
    m_new: mods.m_new.S,
    m_bulk: mods.m_bulk.S,
    m_shipment: mods.m_shipment.S,
    developers: mods.developers.S,
    m_finance: mods.m_finance.S,
    m_settings: mods.m_settings.S,
};
