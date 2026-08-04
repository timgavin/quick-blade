@extends('layouts.app')

@section('content')
    <div class="dashboard">
        @auth
            <h1>Welcome back, {{ $user->name }}!</h1>

            <x-alert type="info" :dismissible="true">
                You have {{ $notifications->count() }} unread notifications.
            </x-alert>

            @can('viewAdmin', App\Models\User::class)
                <x-admin-panel>
                    <x-slot name="header">
                        <h2>Admin Dashboard</h2>
                    </x-slot>

                    <div class="stats">
                        @foreach($stats as $stat)
                            <div class="stat-card">
                                <span class="label">{{ $stat->label }}</span>
                                <span class="value">{!! $stat->formatted_value !!}</span>
                            </div>
                        @endforeach
                    </div>
                </x-admin-panel>
            @endcan

            @if($user->hasTeam())
                <section class="team">
                    <h2>Team Members</h2>
                    @foreach($user->team->members as $member)
                        @include('partials.member-card', ['member' => $member])
                    @endforeach
                </section>
            @else
                <x-empty-state
                    title="No Team"
                    description="Create a team to collaborate with others."
                    icon="users"
                />
            @endif
        @endauth

        @guest
            <div class="guest-welcome">
                <h1>Welcome to {{ config('app.name') }}</h1>
                <p>Please log in to access your dashboard.</p>
                <a href="{{ route('login') }}" class="btn btn-primary">Log In</a>
            </div>
        @endguest
    </div>
@endsection
